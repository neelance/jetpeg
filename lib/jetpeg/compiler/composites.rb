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
        child_types = @children.map(&:return_type).compact
        if not child_types.empty? and child_types.all?(&HashValueType)
          merged = {}
          child_types.each { |type|
            merged.merge!(type.types) { |key, oldval, newval|
              raise CompilationError.new("Duplicate label \"#{key}\".", rule)
            }
          }
          HashValueType.new merged, "#{rule.name}_sequence"
        else
          raise CompilationError.new("Specific return value mixed with labels.", rule) if child_types.any?(&HashValueType)
          raise CompilationError.new("Multiple specific return values.", rule) if child_types.size > 1
          child_types.first
        end
      end
      
      def build(builder, start_input, failed_block)
        result = MergingResult.new builder, start_input, return_type
        previous_fail_cleanup_block = failed_block
        @children.each do |child|
          current_result = child.build builder, result.input, previous_fail_cleanup_block
          result.merge! current_result
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
        result
      end
      
      def get_leftmost_primary
        if @children.first.is_a? Primary
          @children.first
        else
          @children.first.get_leftmost_primary
        end
      end
      
      def replace_leftmost_primary(replacement)
        if @children.first.is_a? Primary
          @children[0] = replacement
          replacement.parent = self
        else
          @children.first.replace_leftmost_primary replacement
        end
      end
    end
    
    class Choice < ParsingExpression
      def self.new(data)
        children = [data[:head]] + data[:tail]
        leftmost_primaries = children.map(&:get_leftmost_primary).uniq
        
        if false #leftmost_primaries.size == 1 and not leftmost_primaries.first.nil?
          #local_label = Label.new expression: leftmost_primaries.first, is_local: true
          local_label = Label.new expression: Sequence.new(children: []), is_local: true
          local_value = LocalValue.new({})
          local_value.local_label = local_label
          
          local_value = leftmost_primaries.first
          children.each { |child| child.replace_leftmost_primary local_value }
          return Sequence.new children: [local_label, super(children)]
        end
        
        super children
      end
      
      def initialize(children)
        super()
        self.children = children
      end
      
      def create_return_type
        @slots = {}
        child_types = @children.map(&:return_type)
        if not child_types.any?
          nil
        elsif child_types.compact.all?(&HashValueType)
          keys = child_types.compact.map(&:types).map(&:keys).flatten.uniq
          return_hash_types = {}
          keys.each do |key|
            all_types = child_types.map { |t| t && t.types[key] }
            return_hash_types[key] = ChoiceValueType.new(all_types, "#{rule.name}_#{key}")
          end
          HashValueType.new return_hash_types, "#{rule.name}_choice_return_value"
        else
          raise CompilationError.new("Specific return value mixed with labels.", rule) if child_types.any?(&HashValueType)
          ChoiceValueType.new child_types, "#{rule.name}_choice_return_value"
        end
      end
      
      def build(builder, start_input, failed_block)
        choice_successful_block = builder.create_block "choice_successful"
        result = BranchingResult.new builder, return_type
        
        @children.each_with_index do |child, index|
          next_child_block = index < @children.size - 1 ? builder.create_block("next_choice_child") : failed_block
          child_result = child.build(builder, start_input, next_child_block)
          result << child_result
          builder.br choice_successful_block
          builder.position_at_end next_child_block
        end
        
        builder.position_at_end choice_successful_block
        result.build
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
        result = BranchingResult.new builder, return_type
        
        optional_failed_block = builder.create_block "optional_failed"
        result << @expression.build(builder, start_input, optional_failed_block)
        builder.br exit_block
        
        builder.position_at_end optional_failed_block
        result << Result.new(start_input)
        builder.br exit_block
        
        builder.position_at_end exit_block
        result.build
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
        return_value << return_type.create_entry(builder, next_result.return_value, return_value) if return_type
        
        builder.br loop_block
        
        builder.position_at_end exit_block
        result = Result.new input
        result.return_value = return_value if return_type
        result
      end
    end
    
    class OneOrMore < ZeroOrMore
      def build(builder, start_input, failed_block)
        result = @expression.build builder, start_input, failed_block
        return_value = return_type.create_entry(builder, result.return_value, return_type.llvm_type.null) if return_type
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
          raise CompilationError.new("Incompatible return values in until expression.", rule) if not loop_type.is_a?(HashValueType) or not until_type.is_a?(HashValueType)
          types = loop_type.types
          types.merge!(until_type.types) { |key, oldval, newval| raise CompilationError.new("Overlapping value in until-expression.", rule) }
          HashValueType.new types, "#{rule.name}_until_entry"
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
        return_value << return_type.create_entry(builder, next_result.return_value, return_value) if return_type
        builder.br loop1_block
        
        builder.position_at_end until_failed_block
        builder.build_free return_type, return_value if return_type
        builder.br failed_block
        
        builder.position_at_end exit_block
        result = Result.new until_result.input
        result.return_value = return_type.create_entry(builder, until_result.return_value, return_value) if return_type
        result
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
        @label_data_ptr = referenced.return_type && referenced.return_type.alloca(builder, "#{@referenced_name}_data_ptr")
      end
      
      def build(builder, start_input, failed_block)
        args = []
        args << start_input
        args << @label_data_ptr if @label_data_ptr
        rule_end_input = builder.call_rule referenced, *args, "rule_end_input"
        
        rule_successful = builder.icmp :ne, rule_end_input, LLVM_STRING.null_pointer, "rule_successful"
        successful_block = builder.create_block "rule_call_successful"
        builder.cond rule_successful, successful_block, failed_block
        
        builder.position_at_end successful_block
        result = Result.new rule_end_input
        if @label_data_ptr
          label_data = builder.load @label_data_ptr, "#{@referenced_name}_data"
          result.return_value = referenced.return_type.read_value builder, label_data
        end
        result
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