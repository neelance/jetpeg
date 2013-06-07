module JetPEG
  module Compiler
    class Sequence < ParsingExpression
      leftmost_leaves :first_child

      block :_entry do
        @first_end_input, @first_has_return_value = build :first_child, @_start_input, :_failed
        @_end_input, @second_has_return_value = build :second_child, @first_end_input, :cleanup_first
        merge_labels i64(2) if @first_has_return_value and @second_has_return_value
        @_has_return_value = @first_has_return_value || @second_has_return_value
        free_local_value :first_child
        free_local_value :second_child
        br :_successful
      end

      block :cleanup_first do
        pop if @first_has_return_value
        free_local_value :first_child
        br :_failed
      end
    end
    
    class Choice < ParsingExpression
      leftmost_leaves :first_child, :second_child

      def self.new(data)
        return super if data[:nested_choice]

        choice = super data
        leftmost_leaf = choice.get_leftmost_leaf
        if leftmost_leaf
          label_name = leftmost_leaf.object_id.to_s
          local_value = LocalValue.new name: label_name
          choice.replace_leftmost_leaf local_value
          local_label = Label.new child: leftmost_leaf, is_local: true, name: label_name
          return Sequence.new first_child: local_label, second_child: choice
        end

        return choice
      end

      block :_entry do
        @first_end_input, @first_has_return_value = build :first_child, @_start_input, :second_child
        br :first_child_exit
      end

      block :second_child do
        @second_end_input, @second_has_return_value = build :second_child, @_start_input, :_failed
        br :second_child_exit
      end

      block :first_child_exit do
        push_empty if not @first_has_return_value and @second_has_return_value
        br :_successful
      end
        
      block :second_child_exit do
        push_empty if not @second_has_return_value and @first_has_return_value
        br :_successful
      end
        
      block :_successful do
        @_end_input = phi LLVM_STRING,
          :first_child_exit => @first_end_input,
          :second_child_exit => @second_end_input
        @_has_return_value = @first_has_return_value || @second_has_return_value
      end
    end
    
    class Repetition < ParsingExpression
      block :_entry do
        @first_child_end_input, @_has_return_value = build :child, @_start_input, @_data[:at_least_once] ? :_failed : :first_failed
        push_array LLVM::TRUE if @_has_return_value
        br :loop
      end

      block :loop do
        @loop_input_phi = phi LLVM_STRING,
          :_entry => @first_child_end_input
        @input = @loop_input_phi
        
        @glue_has_return_value = false
        @input, @glue_has_return_value = build :glue_expression, @input, :break if @_data[:glue_expression]
        pop if @glue_has_return_value

        @child_end_input, _ = build :child, @input, :break
        add_incoming @loop_input_phi, @child_end_input
        append_to_array if @_has_return_value
        br :loop
      end
        
      block :first_failed do
        push_array LLVM::FALSE if @_has_return_value
        br :_successful
      end

      block :break do
        br :_successful
      end

      block :_successful do
        @_end_input = phi LLVM_STRING,
          :first_failed => @_start_input,
          :break => @loop_input_phi
      end
    end

    class Until < ParsingExpression
      block :loop1 do
        @input_phi = phi LLVM_STRING, :_entry => @_start_input
        @_end_input, @until_has_return_value = build :until_expression, @input_phi, :loop2
        append_to_array if @until_has_return_value
        br :_successful
      end
        
      block :loop2 do
        @child_end_input, @child_has_return_value = build :child, @input_phi, :_failed
        add_incoming @input_phi, @child_end_input
        append_to_array if @child_has_return_value
        @_has_return_value = @until_has_return_value || @child_has_return_value
        br :loop1
      end

      block :_entry do
        push_array LLVM::FALSE if @_has_return_value
        br :loop1
      end
    end
    
    class PositiveLookahead < ParsingExpression
      block :_entry do
        _, @has_return_value = build :child, @_start_input, :_failed
        pop if @has_return_value
        br :_successful
      end
    end
    
    class NegativeLookahead < ParsingExpression
      block :_entry do
        _, @has_return_value = build :child, @_start_input, :_successful
        pop if @has_return_value
        br :_failed
      end
    end
    
    class RuleCall < ParsingExpression
      leftmost_leaves :self

      block :_entry do
        @referenced = @_parser[@_data[:name].to_sym]
        @arguments = @_data[:arguments] || []
        raise CompilationError.new("Undefined rule \"#{@_data[:name]}\".", @_current.rule) if @referenced.nil?
        raise CompilationError.new("Wrong argument count for rule \"#{@_data[:name]}\".", @_current.rule) if @referenced.parameters.size != @arguments.size

        @is_direct_recursion = (@referenced == @_current.rule ? LLVM::TRUE : LLVM::FALSE)
        @is_left_recursion = icmp :eq, @_start_input, @_rule_start_input
        @is_direct_left_recursion = self.and @is_direct_recursion, @is_left_recursion
        cond @is_direct_left_recursion, :direct_left_recursion, :no_direct_left_recursion
      end
        
      block :direct_left_recursion do
        store LLVM::TRUE, @_direct_left_recursion_occurred
        @in_recursion_loop = icmp :ne, @_left_recursion_previous_end_input, LLVM_STRING.null
        cond @in_recursion_loop, :in_recursion_loop, :_failed
      end

      block :in_recursion_loop do
        locals_load i64(@_current.get_local_label("<left_recursion_value>", 0)) if @referenced.rule_has_return_value?
        br :_successful
      end
        
      block :no_direct_left_recursion do
        build_all :arguments, @_start_input, :_failed
        locals_push i64(@arguments.size)
        @call_end_input = call @referenced.internal_match_function(@_traced), @_start_input, @_modes, *@_builder.output_functions.values
        locals_pop i64(@arguments.size)
        
        @rule_successful = icmp :ne, @call_end_input, LLVM_STRING.null
        cond @rule_successful, :_successful, :_failed
      end
        
      block :_successful do
        @_end_input = phi LLVM_STRING,
          :in_recursion_loop => @_left_recursion_previous_end_input,
          :no_direct_left_recursion => @call_end_input
        @_has_return_value = @referenced.rule_has_return_value?
      end
    end
    
    class ParenthesizedExpression < ParsingExpression
      leftmost_leaves :child

      block :_entry do
        @_end_input, @_has_return_value = build :child, @_start_input, :_failed
        br :_successful
      end
    end
  end
end