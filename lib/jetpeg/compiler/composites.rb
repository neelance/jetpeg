module JetPEG
  module Compiler
    class Sequence < ParsingExpression
      def initialize(data)
        super()
        self.children = data[:children] || ([data[:head]] + data[:tail])
        
        previous_child = nil
        @children.each do |child|
          child.local_label_source = previous_child
          previous_child = child
        end
      end
  
      def create_return_type
        return @children.first.return_type if @children.size == 1

        child_types = @children.map(&:return_type)
        return nil if not child_types.any?
        
        type = SequenceValueType.new child_types, "#{rule.rule_name}_sequence", parser.value_types
        labels = type.all_labels
        raise CompilationError.new("Invalid mix of return values (#{labels.map(&:inspect).join(', ')}).", rule) if labels.include?(nil) and labels.size != 1
        labels.uniq.each { |name| raise CompilationError.new("Duplicate label \"#{name}\".", rule) if labels.count(name) > 1 }
        type
      end
      
      def build(builder, start_input, modes, failed_block)
        return @children.first.build builder, start_input, modes, failed_block if @children.size == 1
        
        return_value = return_type && builder.create_struct(return_type.llvm_type)
        input = start_input
        
        previous_fail_cleanup_block = failed_block
        @children.each_with_index do |child, index|
          current_result = child.build builder, input, modes, previous_fail_cleanup_block
          input = current_result.input
          return_value = return_type.insert_value builder, return_value, current_result.return_value, index if child.return_type
        
          successful_block = builder.insert_block
          if child.return_type or child.has_local_value?
            current_fail_cleanup_block = builder.create_block "sequence_fail_cleanup"
            builder.position_at_end current_fail_cleanup_block
            builder.call builder.output_functions[:pop] if child.return_type
            builder.call child.return_type.free_function, current_result.return_value if child.return_type
            child.free_local_value builder
            builder.br previous_fail_cleanup_block
            previous_fail_cleanup_block = current_fail_cleanup_block
          end
          
          builder.position_at_end successful_block
        end

        count = @children.count { |child| child.return_type }
        builder.call builder.output_functions[:merge_labels], LLVM::Int64.from_i(count) if count > 1

        @children.each do |child|
          child.free_local_value builder
        end
        
        Result.new input, return_value
      end
    end
    
    class Choice < ParsingExpression
      def initialize(data)
        super()
        self.children = data[:children] || ([data[:head]] + data[:tail])
      end
      
      def create_return_type
        @slots = {}
        child_types = @children.map(&:return_type)
        return nil if not child_types.any?
        ChoiceValueType.new child_types, "#{rule.rule_name}_choice_return_value", parser.value_types
      end
      
      def build(builder, start_input, modes, failed_block)
        choice_successful_block = builder.create_block "choice_successful"
        input_phi = DynamicPhi.new builder, LLVM_STRING, "input"
        return_value_phi = DynamicPhi.new(builder, return_type && return_type.llvm_type, "return_value")

        @children.each_with_index do |child, index|
          next_child_block = index < @children.size - 1 ? builder.create_block("next_choice_child") : failed_block
          
          child_result = child.build(builder, start_input, modes, next_child_block)
          builder.call builder.output_functions[:push_nil] if return_type and child.return_type.nil?
          input_phi << child_result.input
          return_value_phi << (return_type && return_type.create_choice_value(builder, index, child_result))
          
          builder.br choice_successful_block
          builder.position_at_end next_child_block
        end
        
        builder.position_at_end choice_successful_block
        Result.new input_phi.build, return_value_phi.build
      end
    end
    
    class Optional < Choice
      def initialize(data)
        super(children: [data[:expression], EmptyParsingExpression.new])
      end
    end
    
    class ZeroOrMore < ParsingExpression
      def initialize(data)
        super()
        @expression = data[:expression]
        @glue_expression = data[:glue_expression]
        self.children = [@expression, @glue_expression].compact
      end
      
      def create_return_type
        @expression.return_type && ArrayValueType.new(@expression.return_type, "#{rule.rule_name}_loop", parser.value_types)
      end
      
      def build(builder, start_input, modes, failed_block, start_return_value = :none)
        input = DynamicPhi.new builder, LLVM_STRING, "loop_input", start_input
        return_value = DynamicPhi.new builder, (return_type && return_type.llvm_type), "loop_return_value", (start_return_value == :none ? (return_type && return_type.llvm_type.null) : start_return_value)
        match_glue = DynamicPhi.new builder, (@glue_expression && LLVM::Int1), "match_glue", (start_return_value == :none ? LLVM::FALSE : LLVM::TRUE)

        loop_block = builder.create_block "repetition_loop"
        exit_block = builder.create_block "repetition_exit"
        builder.call builder.output_functions[:push_array], LLVM::FALSE if return_type && start_return_value == :none
        builder.br loop_block
        
        builder.position_at_end loop_block
        input.build
        return_value.build
        match_glue.build
        
        if @glue_expression
          glue_block = builder.create_block "repetition_glue"
          expression_block = builder.create_block "repetition_expression"
          input_after_glue = DynamicPhi.new builder, LLVM_STRING, "loop_input_after_glue", input
          builder.cond match_glue, glue_block, expression_block
          
          builder.position_at_end glue_block
          glue_result = @glue_expression.build builder, input, modes, exit_block
          input_after_glue << glue_result.input
          builder.br expression_block
          
          builder.position_at_end expression_block
          input_after_glue.build
        else
          input_after_glue = input
        end
        
        next_result = @expression.build builder, input_after_glue, modes, exit_block
        builder.call builder.output_functions[:append_to_array] if return_type
        input << next_result.input
        return_value << (return_type && return_type.create_array_value(builder, next_result.return_value, return_value))
        match_glue << LLVM::TRUE
        builder.br loop_block
        
        builder.position_at_end exit_block
        Result.new input, return_value
      end
    end
    
    class OneOrMore < ZeroOrMore
      def build(builder, start_input, modes, failed_block)
        result = @expression.build builder, start_input, modes, failed_block
        builder.call builder.output_functions[:push_array], LLVM::TRUE if return_type
        return_value = return_type && return_type.create_array_value(builder, result.return_value, return_type.llvm_type.null)
        super builder, result.input, modes, failed_block, return_value
      end
    end
    
    class Until < ParsingExpression
      def initialize(data)
        super()
        @expression = data[:expression]
        @until_expression = data[:until_expression]
        self.children = [@expression, @until_expression]
      end
      
      def create_return_type
        loop_type = @expression.return_type
        until_type = @until_expression.return_type
        return nil if loop_type.nil? and until_type.nil?
        @choice_type = ChoiceValueType.new([loop_type, until_type], "#{rule.rule_name}_until_choice", parser.value_types)
        ArrayValueType.new(@choice_type, "#{rule.rule_name}_until_array", parser.value_types)
      end
      
      def build(builder, start_input, modes, failed_block)
        loop1_block = builder.create_block "until_loop1"
        loop2_block = builder.create_block "until_loop2"
        until_failed_block = builder.create_block "until_failed"
        exit_block = builder.create_block "until_exit"
        
        input = DynamicPhi.new builder, LLVM_STRING, "loop_input", start_input
        return_value = DynamicPhi.new builder, return_type && return_type.llvm_type, "loop_return_value", return_type && return_type.llvm_type.null
        builder.call builder.output_functions[:push_array], LLVM::FALSE if return_type
        builder.br loop1_block
        
        builder.position_at_end loop1_block
        input.build
        return_value.build
        
        until_result = @until_expression.build builder, input, modes, loop2_block
        builder.call builder.output_functions[:append_to_array] if return_type
        builder.br exit_block
        
        builder.position_at_end loop2_block
        next_result = @expression.build builder, input, modes, until_failed_block
        builder.call builder.output_functions[:append_to_array] if return_type
        input << next_result.input
        return_value << (return_type && return_type.create_array_value(builder, @choice_type.create_choice_value(builder, 0, next_result), return_value))
        builder.br loop1_block
        
        builder.position_at_end until_failed_block
        builder.call return_type.free_function, return_value if return_type
        builder.br failed_block
        
        builder.position_at_end exit_block
        Result.new until_result.input, (return_type && return_type.create_array_value(builder, @choice_type.create_choice_value(builder, 1, until_result), return_value))
      end
    end
    
    class PositiveLookahead < ParsingExpression
      def initialize(data)
        super()
        @expression = data[:expression]
        self.children = [@expression]
      end
  
      def build(builder, start_input, modes, failed_block)
        result = @expression.build builder, start_input, modes, failed_block
        builder.call @expression.return_type.free_function, result.return_value if @expression.return_type
        builder.call builder.output_functions[:pop] if @expression.return_type
        Result.new start_input
      end
    end
    
    class NegativeLookahead < ParsingExpression
      def initialize(data)
        super()
        @expression = data[:expression]
        self.children = [@expression]
      end
  
      def build(builder, start_input, modes, failed_block)
        lookahead_failed_block = builder.create_block "lookahead_failed"
  
        result = @expression.build builder, start_input, modes, lookahead_failed_block
        builder.call @expression.return_type.free_function, result.return_value if @expression.return_type
        builder.call builder.output_functions[:pop] if @expression.return_type
        builder.br failed_block
        
        builder.position_at_end lookahead_failed_block
        Result.new start_input
      end
    end
    
    class RuleCall < Primary
      attr_reader :referenced_name
      
      def initialize(data)
        super()
        @referenced_name = data[:name].to_sym
        @arguments = data[:arguments] || []
        self.children = @arguments
        @recursion = false
      end
      
      def referenced
        @referenced ||= begin
          referenced = parser[@referenced_name]
          raise CompilationError.new("Undefined rule \"#{@referenced_name}\".", rule) if referenced.nil?
          raise CompilationError.new("Wrong argument count for rule \"#{@referenced_name}\".", rule) if referenced.parameters.size != @arguments.size
          referenced
        end
      end
      
      def create_return_type
        begin
          referenced.return_type
        rescue Recursion
          @recursion = true
          rule.has_direct_recursion = true if referenced == rule
          PointerValueType.new referenced, parser.value_types
        end
      end
      
      def build(builder, start_input, modes, failed_block)
        successful_block = builder.create_block "rule_call_successful"
        rule_result_phi = DynamicPhi.new builder, referenced.rule_result_structure

        if referenced == rule
          left_recursion = builder.icmp :eq, start_input, builder.rule_start_input, "left_recursion"
          left_recursion_block, no_left_recursion_block = builder.cond left_recursion
          
          builder.position_at_end left_recursion_block
          if builder.is_left_recursion
            builder.build_use_counter_increment referenced.rule_result_structure, builder.left_recursion_last_result
            rule_result_phi << builder.left_recursion_last_result
            builder.br successful_block
          else
            builder.store LLVM::TRUE, builder.left_recursion_occurred
            builder.br failed_block
          end
          
          builder.position_at_end no_left_recursion_block
        end
        
        call_rule_result = builder.call referenced.internal_match_function(builder.traced, false), start_input, modes, *builder.output_functions.values, *@arguments.map(&:value)
        rule_result_phi << call_rule_result
        
        rule_successful = builder.icmp :ne, builder.extract_value(call_rule_result, 0), LLVM_STRING.null_pointer, "rule_successful"
        builder.cond rule_successful, successful_block, failed_block
        
        builder.position_at_end successful_block
        rule_result = rule_result_phi.build
        return_value = return_type && builder.extract_value(rule_result, 1)
        return_value = return_type.store_value builder, return_value if @recursion
        Result.new builder.extract_value(rule_result, 0), return_value
      end
      
      def ==(other)
        other.is_a?(RuleCall) && other.referenced_name == @referenced_name
      end
    end
    
    class ParenthesizedExpression < ParsingExpression
      def initialize(data)
        super()
        @expression = data[:expression]
        self.children = [@expression] if @expression
      end
      
      def create_return_type
        @expression && @expression.return_type
      end
      
      def build(builder, start_input, modes, failed_block)
        return Result.new start_input if @expression.nil?
        @expression.build builder, start_input, modes, failed_block
      end
    end
  end
end