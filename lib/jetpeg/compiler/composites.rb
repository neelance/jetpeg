module JetPEG
  module Compiler
    class Sequence < ParsingExpression
      def collect_children
        @data[:children]
      end

      def build(builder, start_input, modes, failed_block)
        input = start_input
        previous_fail_cleanup_block = failed_block
        return_value_count = 0
        children.each_with_index do |child, index|
          input, has_return_value = child.build builder, input, modes, previous_fail_cleanup_block
          return_value_count += 1 if has_return_value
        
          successful_block = builder.insert_block
          if has_return_value or child.has_local_value?
            current_fail_cleanup_block = builder.create_block "sequence_fail_cleanup"
            builder.position_at_end current_fail_cleanup_block
            builder.call builder.output_functions[:pop] if has_return_value
            child.free_local_value builder
            builder.br previous_fail_cleanup_block
            previous_fail_cleanup_block = current_fail_cleanup_block
          end
          
          builder.position_at_end successful_block
        end

        builder.call builder.output_functions[:merge_labels], LLVM::Int64.from_i(return_value_count) if return_value_count > 1

        children.each do |child|
          child.free_local_value builder
        end
        
        return input, return_value_count != 0
      end
    end
    
    class Choice < ParsingExpression
      def self.new(data)
        first_leftmost_leaf = data[:first_child].get_leftmost_leaf
        second_leftmost_leaf = data[:second_child].get_leftmost_leaf
        if not first_leftmost_leaf.nil? and first_leftmost_leaf == second_leftmost_leaf
          label_name = self.object_id.to_s

          local_value = LocalValue.new name: label_name
          data[:first_child].replace_leftmost_leaf local_value
          data[:second_child].replace_leftmost_leaf local_value

          local_label = Label.new child: first_leftmost_leaf, is_local: true, name: label_name
          return Sequence.new children: [local_label, super]
        end
        
        super
      end

      def collect_children
        [data[:first_child], data[:second_child]]
      end
      
      def get_leftmost_leaf
        first_leftmost_leaf = @data[:first_child].get_leftmost_leaf
        second_leftmost_leaf = @data[:second_child].get_leftmost_leaf
        first_leftmost_leaf == second_leftmost_leaf ? first_leftmost_leaf : nil
      end
      
      def replace_leftmost_leaf(replacement)
        @data[:first_child].replace_leftmost_leaf replacement
        @data[:second_child].replace_leftmost_leaf replacement
      end

      def build(builder, start_input, modes, failed_block)
        second_child_block = builder.create_block "choice_second_child"
        choice_successful_block = builder.create_block "choice_successful"
        input_phi = DynamicPhi.new builder, LLVM_STRING, "input"

        first_end_input, first_has_return_value = @data[:first_child].build builder, start_input, modes, second_child_block
        input_phi << first_end_input
        first_child_exit_block = builder.insert_block

        builder.position_at_end second_child_block
        second_end_input, second_has_return_value = @data[:second_child].build builder, start_input, modes, failed_block
        input_phi << second_end_input
        second_child_exit_block = builder.insert_block

        builder.position_at_end first_child_exit_block
        builder.call builder.output_functions[:push_nil] if not first_has_return_value and second_has_return_value
        builder.br choice_successful_block
        
        builder.position_at_end second_child_exit_block
        builder.call builder.output_functions[:push_nil] if not second_has_return_value and first_has_return_value
        builder.br choice_successful_block
        
        builder.position_at_end choice_successful_block
        return input_phi.build, first_has_return_value || second_has_return_value
      end
    end
    
    class Repetition < ParsingExpression
      def collect_children
        [@data[:child]] + (@data[:glue_expression] ? [@data[:glue_expression]] : [])
      end
      
      def build(builder, start_input, modes, failed_block)
        first_failed_block = builder.create_block "repetition_first_failed"
        loop_block = builder.create_block "repetition_loop"
        break_block = builder.create_block "repetition_break"
        exit_block = builder.create_block "repetition_exit"
        
        loop_input = DynamicPhi.new builder, LLVM_STRING, "loop_input"
        exit_input = DynamicPhi.new builder, LLVM_STRING, "exit_input"

        child_end_input, has_return_value = children.first.build builder, start_input, modes, @data[:at_least_once] ? failed_block : first_failed_block
        loop_input << child_end_input
        builder.call builder.output_functions[:push_array], LLVM::TRUE if has_return_value
        builder.br loop_block
        
        builder.position_at_end loop_block
        loop_input.build
        input = loop_input

        if @data[:glue_expression]
          input, glue_has_return_value = @data[:glue_expression].build builder, input, modes, break_block
          builder.call builder.output_functions[:pop] if glue_has_return_value
        end

        child_end_input, _ = children.first.build builder, input, modes, break_block
        loop_input << child_end_input
        builder.call builder.output_functions[:append_to_array] if has_return_value

        builder.br loop_block
        
        builder.position_at_end first_failed_block
        builder.call builder.output_functions[:push_array], LLVM::FALSE if has_return_value
        exit_input << start_input
        builder.br exit_block

        builder.position_at_end break_block
        exit_input << loop_input
        builder.br exit_block

        builder.position_at_end exit_block
        return exit_input.build, has_return_value
      end
    end

    class Until < ParsingExpression
      def collect_children
        [@data[:child], @data[:until_expression]]
      end
      
      def build(builder, start_input, modes, failed_block)
        loop1_block = builder.create_block "until_loop1"
        loop2_block = builder.create_block "until_loop2"
        exit_block = builder.create_block "until_exit"
        
        input = DynamicPhi.new builder, LLVM_STRING, "loop_input", start_input
        entry_block = builder.insert_block
        
        builder.position_at_end loop1_block
        input.build
        until_end_input, until_has_return_value = @data[:until_expression].build builder, input, modes, loop2_block
        builder.call builder.output_functions[:append_to_array] if until_has_return_value
        builder.br exit_block
        
        builder.position_at_end loop2_block
        child_end_input, child_has_return_value = children.first.build builder, input, modes, failed_block
        input << child_end_input
        builder.call builder.output_functions[:append_to_array] if child_has_return_value
        builder.br loop1_block

        builder.position_at_end entry_block
        builder.call builder.output_functions[:push_array], LLVM::FALSE if until_has_return_value || child_has_return_value
        builder.br loop1_block

        builder.position_at_end exit_block
        return until_end_input, until_has_return_value || child_has_return_value
      end
    end
    
    class PositiveLookahead < ParsingExpression
      def build(builder, start_input, modes, failed_block)
        _, has_return_value = children.first.build builder, start_input, modes, failed_block
        builder.call builder.output_functions[:pop] if has_return_value
        return start_input, false
      end
    end
    
    class NegativeLookahead < ParsingExpression
      def build(builder, start_input, modes, failed_block)
        lookahead_failed_block = builder.create_block "lookahead_failed"
  
        _, has_return_value = children.first.build builder, start_input, modes, lookahead_failed_block
        builder.call builder.output_functions[:pop] if has_return_value
        builder.br failed_block
        
        builder.position_at_end lookahead_failed_block
        return start_input, false
      end
    end
    
    class RuleCall < ParsingExpression
      def collect_children
        @data[:arguments] || []
      end
      
      def referenced
        @referenced ||= begin
          referenced = parser[@data[:name].to_sym]
          raise CompilationError.new("Undefined rule \"#{@data[:name]}\".", rule) if referenced.nil?
          raise CompilationError.new("Wrong argument count for rule \"#{@data[:name]}\".", rule) if referenced.parameters.size != children.size
          referenced
        end
      end
      
      def build(builder, start_input, modes, failed_block)
        successful_block = builder.create_block "rule_call_successful"
        rule_end_input_phi = DynamicPhi.new builder, LLVM_STRING

        if referenced == rule
          direct_left_recursion_block = builder.create_block "direct_left_recursion"
          no_direct_left_recursion_block = builder.create_block "no_direct_left_recursion"
          is_direct_left_recursion = builder.icmp :eq, start_input, builder.rule_start_input, "is_direct_left_recursion"
          builder.cond is_direct_left_recursion, direct_left_recursion_block, no_direct_left_recursion_block
          
          builder.position_at_end direct_left_recursion_block
          builder.store LLVM::TRUE, builder.direct_left_recursion_occurred
          in_recursion_loop = builder.icmp :ne, builder.left_recursion_previous_end_input, LLVM_STRING.null, "in_recursion_loop"
          in_recursion_loop_block = builder.create_block "in_recursion_loop"
          builder.cond in_recursion_loop, in_recursion_loop_block, failed_block

          builder.position_at_end in_recursion_loop_block
          rule_end_input_phi << builder.left_recursion_previous_end_input
          builder.call builder.output_functions[:locals_load], LLVM::Int64.from_i(get_local_label("<left_recursion_value>", 0)) if referenced.rule_has_return_value?
          builder.br successful_block
          
          builder.position_at_end no_direct_left_recursion_block
        end
        
        children.each { |arg| arg.build builder, start_input, modes, failed_block }
        children.size.times { builder.call builder.output_functions[:locals_push] }
        call_end_input = builder.call referenced.internal_match_function(builder.traced), start_input, modes, *builder.output_functions.values
        rule_end_input_phi << call_end_input
        children.size.times { builder.call builder.output_functions[:locals_pop] }
        
        rule_successful = builder.icmp :ne, call_end_input, LLVM_STRING.null, "rule_successful"
        builder.cond rule_successful, successful_block, failed_block
        
        builder.position_at_end successful_block
        return rule_end_input_phi.build, referenced.rule_has_return_value?
      end
    end
    
    class ParenthesizedExpression < ParsingExpression
      def build(builder, start_input, modes, failed_block)
        return children.first.build builder, start_input, modes, failed_block
      end
    end
  end
end