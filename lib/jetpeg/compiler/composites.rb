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
  
      def calculate_has_return_value
        return @children.first.has_return_value if @children.size == 1

        child_types = @children.map(&:has_return_value)
        return nil if not child_types.any?
        
        true
      end
      
      def build(builder, start_input, modes, failed_block)
        return @children.first.build builder, start_input, modes, failed_block if @children.size == 1
        
        input = start_input
        previous_fail_cleanup_block = failed_block
        @children.each_with_index do |child, index|
          input = child.build builder, input, modes, previous_fail_cleanup_block
        
          successful_block = builder.insert_block
          if child.has_return_value or child.has_local_value?
            current_fail_cleanup_block = builder.create_block "sequence_fail_cleanup"
            builder.position_at_end current_fail_cleanup_block
            builder.call builder.output_functions[:pop] if child.has_return_value
            child.free_local_value builder
            builder.br previous_fail_cleanup_block
            previous_fail_cleanup_block = current_fail_cleanup_block
          end
          
          builder.position_at_end successful_block
        end

        count = @children.count { |child| child.has_return_value }
        builder.call builder.output_functions[:merge_labels], LLVM::Int64.from_i(count) if count > 1

        @children.each do |child|
          child.free_local_value builder
        end
        
        input
      end
    end
    
    class Choice < ParsingExpression
      def initialize(data)
        super()
        self.children = data[:children] || ([data[:head]] + data[:tail])
      end
      
      def calculate_has_return_value
        @slots = {}
        child_types = @children.map(&:has_return_value)
        return nil if not child_types.any?
        true
      end
      
      def build(builder, start_input, modes, failed_block)
        choice_successful_block = builder.create_block "choice_successful"
        input_phi = DynamicPhi.new builder, LLVM_STRING, "input"

        @children.each_with_index do |child, index|
          next_child_block = index < @children.size - 1 ? builder.create_block("next_choice_child") : failed_block
          
          input_phi << child.build(builder, start_input, modes, next_child_block)
          builder.call builder.output_functions[:push_nil] if has_return_value and child.has_return_value.nil?
          
          builder.br choice_successful_block
          builder.position_at_end next_child_block
        end
        
        builder.position_at_end choice_successful_block
        input_phi.build
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
      
      def calculate_has_return_value
        @expression.has_return_value
      end
      
      def build(builder, start_input, modes, failed_block, one_or_more = false)
        input = DynamicPhi.new builder, LLVM_STRING, "loop_input", start_input
        match_glue = DynamicPhi.new builder, (@glue_expression && LLVM::Int1), "match_glue", (one_or_more ? LLVM::TRUE : LLVM::FALSE)

        loop_block = builder.create_block "repetition_loop"
        exit_block = builder.create_block "repetition_exit"
        builder.call builder.output_functions[:push_array], LLVM::FALSE if has_return_value and not one_or_more
        builder.br loop_block
        
        builder.position_at_end loop_block
        input.build
        match_glue.build
        
        if @glue_expression
          glue_block = builder.create_block "repetition_glue"
          expression_block = builder.create_block "repetition_expression"
          input_after_glue = DynamicPhi.new builder, LLVM_STRING, "loop_input_after_glue", input
          builder.cond match_glue, glue_block, expression_block
          
          builder.position_at_end glue_block
          input_after_glue << @glue_expression.build(builder, input, modes, exit_block)
          builder.br expression_block
          
          builder.position_at_end expression_block
          input_after_glue.build
        else
          input_after_glue = input
        end
        
        input << @expression.build(builder, input_after_glue, modes, exit_block)
        builder.call builder.output_functions[:append_to_array] if has_return_value
        match_glue << LLVM::TRUE
        builder.br loop_block
        
        builder.position_at_end exit_block
        input
      end
    end
    
    class OneOrMore < ZeroOrMore
      def build(builder, start_input, modes, failed_block)
        input = @expression.build builder, start_input, modes, failed_block
        builder.call builder.output_functions[:push_array], LLVM::TRUE if has_return_value
        super builder, input, modes, failed_block, true
      end
    end
    
    class Until < ParsingExpression
      def initialize(data)
        super()
        @expression = data[:expression]
        @until_expression = data[:until_expression]
        self.children = [@expression, @until_expression]
      end
      
      def calculate_has_return_value
        loop_type = @expression.has_return_value
        until_type = @until_expression.has_return_value
        return nil if loop_type.nil? and until_type.nil?
        true
      end
      
      def build(builder, start_input, modes, failed_block)
        loop1_block = builder.create_block "until_loop1"
        loop2_block = builder.create_block "until_loop2"
        until_failed_block = builder.create_block "until_failed"
        exit_block = builder.create_block "until_exit"
        
        input = DynamicPhi.new builder, LLVM_STRING, "loop_input", start_input
        builder.call builder.output_functions[:push_array], LLVM::FALSE if has_return_value
        builder.br loop1_block
        
        builder.position_at_end loop1_block
        input.build
        
        until_end_input = @until_expression.build builder, input, modes, loop2_block
        builder.call builder.output_functions[:append_to_array] if has_return_value
        builder.br exit_block
        
        builder.position_at_end loop2_block
        input << @expression.build(builder, input, modes, until_failed_block)
        builder.call builder.output_functions[:append_to_array] if has_return_value
        builder.br loop1_block
        
        builder.position_at_end until_failed_block
        builder.br failed_block
        
        builder.position_at_end exit_block
        until_end_input
      end
    end
    
    class PositiveLookahead < ParsingExpression
      def initialize(data)
        super()
        @expression = data[:expression]
        self.children = [@expression]
      end
  
      def build(builder, start_input, modes, failed_block)
        @expression.build builder, start_input, modes, failed_block
        builder.call builder.output_functions[:pop] if @expression.has_return_value
        start_input
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
  
        @expression.build builder, start_input, modes, lookahead_failed_block
        builder.call builder.output_functions[:pop] if @expression.has_return_value
        builder.br failed_block
        
        builder.position_at_end lookahead_failed_block
        start_input
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
      
      def calculate_has_return_value
        begin
          referenced.has_return_value
        rescue Recursion
          @recursion = true
          rule.has_direct_recursion = true if referenced == rule
          true
        end
      end
      
      def build(builder, start_input, modes, failed_block)
        successful_block = builder.create_block "rule_call_successful"
        rule_end_input_phi = DynamicPhi.new builder, LLVM_STRING

        if referenced == rule
          left_recursion = builder.icmp :eq, start_input, builder.rule_start_input, "left_recursion"
          left_recursion_block, no_left_recursion_block = builder.cond left_recursion
          
          builder.position_at_end left_recursion_block
          if builder.is_left_recursion
            rule_end_input_phi << builder.left_recursion_previous_end_input
            builder.br successful_block
          else
            builder.store LLVM::TRUE, builder.left_recursion_occurred
            builder.br failed_block
          end
          
          builder.position_at_end no_left_recursion_block
        end
        
        call_end_input = builder.call referenced.internal_match_function(builder.traced, false), start_input, modes, *builder.output_functions.values
        rule_end_input_phi << call_end_input
        
        rule_successful = builder.icmp :ne, call_end_input, LLVM_STRING.null, "rule_successful"
        builder.cond rule_successful, successful_block, failed_block
        
        builder.position_at_end successful_block
        rule_end_input_phi.build
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
      
      def calculate_has_return_value
        @expression && @expression.has_return_value
      end
      
      def build(builder, start_input, modes, failed_block)
        return start_input if @expression.nil?
        @expression.build builder, start_input, modes, failed_block
      end
    end
  end
end