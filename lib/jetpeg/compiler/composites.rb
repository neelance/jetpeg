module JetPEG
  module Compiler
    class Sequence < ParsingExpression
      def initialize(data)
        super
        self.children = data[:children] || ([data[:head]] + data[:tail])
        
        previous_child = nil
        @children.each do |child|
          child.local_label_source = previous_child
          previous_child = child
        end
      end
  
      def calculate_has_return_value?
        @children.any?(&:has_return_value?)
      end
      
      def build(builder, start_input, modes, failed_block)
        input = start_input
        previous_fail_cleanup_block = failed_block
        @children.each_with_index do |child, index|
          input = child.build builder, input, modes, previous_fail_cleanup_block
        
          successful_block = builder.insert_block
          if child.has_return_value? or child.has_local_value?
            current_fail_cleanup_block = builder.create_block "sequence_fail_cleanup"
            builder.position_at_end current_fail_cleanup_block
            builder.call builder.output_functions[:pop] if child.has_return_value?
            child.free_local_value builder
            builder.br previous_fail_cleanup_block
            previous_fail_cleanup_block = current_fail_cleanup_block
          end
          
          builder.position_at_end successful_block
        end

        count = @children.count(&:has_return_value?)
        builder.call builder.output_functions[:merge_labels], LLVM::Int64.from_i(count) if count > 1

        @children.each do |child|
          child.free_local_value builder
        end
        
        input
      end
    end
    
    class Choice < ParsingExpression
      def self.new(data)
        children = data[:children] || ([data[:head]] + data[:tail])
        leftmost_primaries = children.map(&:get_leftmost_primary).uniq
        if leftmost_primaries.size == 1 and not leftmost_primaries.first.nil?
          label_name = self.object_id.to_s
          local_label = Label.new child: leftmost_primaries.first, is_local: true, name: label_name
          local_value = LocalValue.new name: label_name
          
          children.each { |child| child.replace_leftmost_primary local_value }
          return Sequence.new children: [local_label, Choice.new(children: children)]
        end
        
        super
      end

      def initialize(data)
        super
        self.children = data[:children] || ([data[:head]] + data[:tail])
      end
      
      def calculate_has_return_value?
        @children.any?(&:has_return_value?)
      end
      
      def build(builder, start_input, modes, failed_block)
        choice_successful_block = builder.create_block "choice_successful"
        input_phi = DynamicPhi.new builder, LLVM_STRING, "input"

        @children.each_with_index do |child, index|
          next_child_block = index < @children.size - 1 ? builder.create_block("next_choice_child") : failed_block
          
          input_phi << child.build(builder, start_input, modes, next_child_block)
          builder.call builder.output_functions[:push_nil] if has_return_value? and not child.has_return_value?
          
          builder.br choice_successful_block
          builder.position_at_end next_child_block
        end
        
        builder.position_at_end choice_successful_block
        input_phi.build
      end
    end
    
    class Repetition < ParsingExpression
      def initialize(data)
        super
        @expression = data[:child]
        @glue_expression = data[:glue_expression]
        @at_least_once = data[:at_least_once]
        self.children = [@expression, @glue_expression].compact
      end
      
      def calculate_has_return_value?
        @expression.has_return_value?
      end
      
      def build(builder, start_input, modes, failed_block)
        first_failed_block = builder.create_block "repetition_first_failed"
        loop_block = builder.create_block "repetition_loop"
        break_block = builder.create_block "repetition_break"
        exit_block = builder.create_block "repetition_exit"
        
        loop_input = DynamicPhi.new builder, LLVM_STRING, "loop_input"
        exit_input = DynamicPhi.new builder, LLVM_STRING, "exit_input"

        loop_input << @expression.build(builder, start_input, modes, @at_least_once ? failed_block : first_failed_block)
        builder.call builder.output_functions[:push_array], LLVM::TRUE if has_return_value?
        builder.br loop_block
        
        builder.position_at_end loop_block
        loop_input.build
        input = loop_input

        if @glue_expression
          input = @glue_expression.build builder, input, modes, break_block
          builder.call builder.output_functions[:pop] if @glue_expression.has_return_value?
        end

        loop_input << @expression.build(builder, input, modes, break_block)
        builder.call builder.output_functions[:append_to_array] if has_return_value?

        builder.br loop_block
        
        builder.position_at_end first_failed_block
        builder.call builder.output_functions[:push_array], LLVM::FALSE if has_return_value?
        exit_input << start_input
        builder.br exit_block

        builder.position_at_end break_block
        exit_input << loop_input
        builder.br exit_block

        builder.position_at_end exit_block
        exit_input.build
      end
    end

    class Until < ParsingExpression
      def initialize(data)
        super
        @expression = data[:child]
        @until_expression = data[:until_expression]
        self.children = [@expression, @until_expression]
      end
      
      def calculate_has_return_value?
        @expression.has_return_value? || @until_expression.has_return_value?
      end
      
      def build(builder, start_input, modes, failed_block)
        loop1_block = builder.create_block "until_loop1"
        loop2_block = builder.create_block "until_loop2"
        exit_block = builder.create_block "until_exit"
        
        input = DynamicPhi.new builder, LLVM_STRING, "loop_input", start_input
        builder.call builder.output_functions[:push_array], LLVM::FALSE if has_return_value?
        builder.br loop1_block
        
        builder.position_at_end loop1_block
        input.build
        until_end_input = @until_expression.build builder, input, modes, loop2_block
        builder.call builder.output_functions[:append_to_array] if @until_expression.has_return_value?
        builder.br exit_block
        
        builder.position_at_end loop2_block
        input << @expression.build(builder, input, modes, failed_block)
        builder.call builder.output_functions[:append_to_array] if @expression.has_return_value?
        builder.br loop1_block
        
        builder.position_at_end exit_block
        until_end_input
      end
    end
    
    class PositiveLookahead < ParsingExpression
      def initialize(data)
        super
        @expression = data[:child]
        self.children = [@expression]
      end
  
      def build(builder, start_input, modes, failed_block)
        @expression.build builder, start_input, modes, failed_block
        builder.call builder.output_functions[:pop] if @expression.has_return_value?
        start_input
      end
    end
    
    class NegativeLookahead < ParsingExpression
      def initialize(data)
        super
        @expression = data[:child]
        self.children = [@expression]
      end
  
      def build(builder, start_input, modes, failed_block)
        lookahead_failed_block = builder.create_block "lookahead_failed"
  
        @expression.build builder, start_input, modes, lookahead_failed_block
        builder.call builder.output_functions[:pop] if @expression.has_return_value?
        builder.br failed_block
        
        builder.position_at_end lookahead_failed_block
        start_input
      end
    end
    
    class RuleCall < ParsingExpression
      def initialize(data)
        super
        @arguments = data[:arguments] || []
        self.children = @arguments
        @recursion = false
      end
      
      def referenced
        @referenced ||= begin
          referenced = parser[@data[:name].to_sym]
          raise CompilationError.new("Undefined rule \"#{@data[:name]}\".", rule) if referenced.nil?
          raise CompilationError.new("Wrong argument count for rule \"#{@data[:name]}\".", rule) if referenced.parameters.size != @arguments.size
          referenced
        end
      end
      
      def calculate_has_return_value?
        begin
          referenced.has_return_value?
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
        
        @arguments.each { |arg| arg.build builder, start_input, modes, failed_block }
        @arguments.size.times { builder.call builder.output_functions[:locals_push] }
        call_end_input = builder.call referenced.internal_match_function(builder.traced, false), start_input, modes, *builder.output_functions.values
        rule_end_input_phi << call_end_input
        @arguments.size.times { builder.call builder.output_functions[:locals_pop] }
        
        rule_successful = builder.icmp :ne, call_end_input, LLVM_STRING.null, "rule_successful"
        builder.cond rule_successful, successful_block, failed_block
        
        builder.position_at_end successful_block
        rule_end_input_phi.build
      end

      def is_primary
        true
      end
    end
    
    class ParenthesizedExpression < ParsingExpression
      def initialize(data)
        super
        @expression = data[:child]
        self.children = [@expression] if @expression
      end
      
      def calculate_has_return_value?
        @expression && @expression.has_return_value?
      end
      
      def build(builder, start_input, modes, failed_block)
        return start_input if @expression.nil?
        @expression.build builder, start_input, modes, failed_block
      end
    end
  end
end