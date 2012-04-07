module JetPEG
  module Compiler
    class Sequence < ParsingExpression
      def initialize(data)
        super()
        self.children = data[:children] || [data[:head]] + data[:tail]
        
        previous_child = nil
        @children.each do |child|
          child.local_label_source = previous_child
          previous_child = child
        end
      end
  
      def create_return_type
        child_types = @children.map(&:return_type)
        return nil if not child_types.any?

        type = SequenceValueType.new child_types, "#{rule.name}_sequence"
        labels = type.all_labels
        raise CompilationError.new("Invalid mix of return values (#{labels.map(&:inspect).join(', ')}).", rule) if labels.include?(nil) and labels.size != 1
        labels.uniq.each { |name| raise CompilationError.new("Duplicate label \"#{name}\".", rule) if labels.count(name) > 1 }
        type
      end
      
      def build(builder, start_input, failed_block)
        return_value = return_type && builder.create_struct(return_type.llvm_type)
        input = start_input
        
        previous_fail_cleanup_block = failed_block
        @children.each_with_index do |child, index|
          current_result = child.build builder, input, previous_fail_cleanup_block
          input = current_result.input
          return_value = return_type.insert_value builder, return_value, current_result.return_value, index if child.return_type
        
          successful_block = builder.insert_block
          if child.return_type or child.has_local_value?
            current_fail_cleanup_block = builder.create_block "sequence_fail_cleanup"
            builder.position_at_end current_fail_cleanup_block
            builder.build_free child.return_type, current_result.return_value if child.return_type
            child.free_local_value builder
            builder.br previous_fail_cleanup_block
            previous_fail_cleanup_block = current_fail_cleanup_block
          end
          
          builder.position_at_end successful_block
        end
        
        @children.each do |child|
          child.free_local_value builder
        end
        
        Result.new input, return_value
      end
    end
    
    class Choice < ParsingExpression
      def initialize(data)
        super()
        self.children = data[:children] || [data[:head]] + data[:tail]
      end
      
      def create_return_type
        @slots = {}
        child_types = @children.map(&:return_type)
        if child_types.compact.empty?
          nil
        else
          ChoiceValueType.new child_types, "#{rule.name}_choice_return_value"
        end
      end
      
      def build(builder, start_input, failed_block)
        choice_successful_block = builder.create_block "choice_successful"
        input_phi = DynamicPhi.new builder, LLVM_STRING, "input"
        return_value_phi = return_type && DynamicPhi.new(builder, return_type, "return_value")

        @children.each_with_index do |child, index|
          next_child_block = index < @children.size - 1 ? builder.create_block("next_choice_child") : failed_block
          
          child_result = child.build(builder, start_input, next_child_block)
          input_phi << child_result.input
          if return_type
            struct = return_type.llvm_type.null
            struct = builder.insert_value struct, LLVM::Int(index), 0
            struct = return_type.insert_value builder, struct, child_result.return_value, index if child_result.return_value
            return_value_phi << struct
          end

          builder.br choice_successful_block
          builder.position_at_end next_child_block
        end
        
        builder.position_at_end choice_successful_block
        Result.new input_phi.build, (return_value_phi && return_value_phi.build)
      end
    end
    
    class Optional < ParsingExpression
      def initialize(data)
        super()
        @expression = data[:expression]
        self.children = [@expression]
      end
      
      def create_return_type
        @expression.return_type
      end
      
      def build(builder, start_input, failed_block)
        exit_block = builder.create_block "optional_exit"
        input_phi = DynamicPhi.new builder, LLVM_STRING, "input"
        return_value_phi = DynamicPhi.new(builder, return_type, "return_value") if return_type

        optional_failed_block = builder.create_block "optional_failed"
        child_result = @expression.build builder, start_input, optional_failed_block
        input_phi << child_result.input
        return_value_phi << child_result.return_value if return_type
        builder.br exit_block
        
        builder.position_at_end optional_failed_block
        input_phi << start_input
        return_value_phi << nil if return_type
        builder.br exit_block
        
        builder.position_at_end exit_block
        Result.new input_phi.build, (return_value_phi && return_value_phi.build)
      end
    end
    
    class ZeroOrMore < ParsingExpression
      def initialize(data)
        super()
        @expression = data[:expression]
        self.children = [@expression]
      end
      
      def create_return_type
        @expression.return_type && ArrayValueType.new(@expression.return_type, "#{rule.name}_loop")
      end
      
      def build(builder, start_input, failed_block = {}, start_return_value = nil)
        loop_block = builder.create_block "repetition_loop"
        exit_block = builder.create_block "repetition_exit"
  
        input = DynamicPhi.new builder, LLVM_STRING, "loop_input", start_input
        return_value = DynamicPhi.new builder, return_type, "loop_return_value", start_return_value || return_type.llvm_type.null if return_type
        builder.br loop_block
        
        builder.position_at_end loop_block
        input.build
        return_value.build if return_type
        
        next_result = @expression.build builder, input, exit_block
        input << next_result.input
        return_value << return_type.create_entry(builder, next_result, return_value) if return_type
        
        builder.br loop_block
        
        builder.position_at_end exit_block
        Result.new input, return_value
      end
    end
    
    class OneOrMore < ZeroOrMore
      def build(builder, start_input, failed_block)
        result = @expression.build builder, start_input, failed_block
        return_value = return_type.create_entry(builder, result, return_type.llvm_type.null) if return_type
        super builder, result.input, failed_block, return_value
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
        entry_type = if loop_type && until_type
          raise CompilationError.new("Incompatible return values in until expression.", rule) if not loop_type.is_a?(SequenceValueType) or not until_type.is_a?(SequenceValueType)
          types = loop_type.types.merge(until_type.types) { |key, oldval, newval| raise CompilationError.new("Overlapping value in until-expression.", rule) }
          SequenceValueType.new types, "#{rule.name}_until_entry"
        else
          loop_type || until_type
        end
        entry_type && ArrayValueType.new(entry_type, "#{rule.name}_until")
      end
      
      def build(builder, start_input, failed_block)
        loop1_block = builder.create_block "until_loop1"
        loop2_block = builder.create_block "until_loop2"
        until_failed_block = builder.create_block "until_failed"
        exit_block = builder.create_block "until_exit"
        
        input = DynamicPhi.new builder, LLVM_STRING, "loop_input", start_input
        return_value = DynamicPhi.new builder, return_type.llvm_type, "loop_return_value", return_type.llvm_type.null if return_type
        builder.br loop1_block
        
        builder.position_at_end loop1_block
        input.build
        return_value.build if return_type
        
        until_result = @until_expression.build builder, input, loop2_block
        builder.br exit_block
        
        builder.position_at_end loop2_block
        next_result = @expression.build builder, input, until_failed_block
        input << next_result.input
        return_value << return_type.create_entry(builder, next_result, return_value) if return_type
        builder.br loop1_block
        
        builder.position_at_end until_failed_block
        builder.build_free return_type, return_value if return_type
        builder.br failed_block
        
        builder.position_at_end exit_block
        Result.new until_result.input, (return_type && return_type.create_entry(builder, until_result, return_value))
      end
    end
    
    class PositiveLookahead < ParsingExpression
      def initialize(data)
        super()
        @expression = data[:expression]
        self.children = [@expression]
      end
  
      def build(builder, start_input, failed_block)
        result = @expression.build builder, start_input, failed_block
        builder.build_free @expression.return_type, result.return_value if @expression.return_type
        Result.new start_input
      end
    end
    
    class NegativeLookahead < ParsingExpression
      def initialize(data)
        super()
        @expression = data[:expression]
        self.children = [@expression]
      end
  
      def build(builder, start_input, failed_block)
        lookahead_failed_block = builder.create_block "lookahead_failed"
  
        result = @expression.build builder, start_input, lookahead_failed_block
        builder.build_free @expression.return_type, result.return_value if @expression.return_type
        builder.br failed_block
        
        builder.position_at_end lookahead_failed_block
        Result.new start_input
      end
    end
    
    class RuleName < Primary
      attr_reader :referenced_name
      
      def initialize(data)
        super()
        @referenced_name = data[:name].to_sym
      end
      
      def referenced
        @referenced ||= parser[@referenced_name] || raise(CompilationError.new("Undefined rule \"#{name}\".", rule))
      end
      
      def create_return_type
        referenced.return_type
      end
      
      def build_allocas(builder)
        @label_data_ptr = return_type && return_type.alloca(builder, "#{@referenced_name}_data_ptr")
      end
      
      def build(builder, start_input, failed_block)
        args = []
        args << start_input
        args << @label_data_ptr if return_type
        rule_end_input = builder.call_rule referenced, *args, "rule_end_input"
        
        rule_successful = builder.icmp :ne, rule_end_input, LLVM_STRING.null_pointer, "rule_successful"
        successful_block = builder.create_block "rule_call_successful"
        builder.cond rule_successful, successful_block, failed_block
        
        builder.position_at_end successful_block
        return_value = return_type && builder.load(@label_data_ptr, "#{@referenced_name}_data")
        Result.new rule_end_input, return_value
      end
      
      def ==(other)
        other.is_a?(RuleName) && other.referenced_name == @referenced_name
      end
    end
    
    class ParenthesizedExpression < ParsingExpression
      def initialize(data)
        super()
        @expression = data[:expression]
        self.children = [@expression]
      end
      
      def create_return_type
        @expression.return_type
      end
      
      def build(builder, start_input, failed_block)
        @expression.build builder, start_input, failed_block
      end
    end
  end
end