module JetPEG
  module Compiler
    class ParsingExpression
      attr_accessor :parent, :name, :parameters, :local_label_source
      attr_reader :rule_function
      
      def initialize
        @name = nil
        @parameters = []
        @children = []
        @return_type = :pending
        @return_type_recursion = false
        @fast_rule_function = nil
        @traced_rule_function = nil
        @local_label_source = nil
      end
      
      def children=(array)
        @children = array
        @children.each { |child| child.parent = self }
      end
      
      def parser
        @parent.parser
      end
      
      def metagrammar?
        parser == JetPEG::Compiler.metagrammar_parser
      end
      
      def rule
        @name ? self : parent.rule
      end
      
      def return_type
        if @return_type == :pending
          raise Recursion.new(self) if @return_type_recursion
          begin
            @return_type_recursion = true
            @return_type = create_return_type
          rescue Recursion => recursion
            raise recursion if not recursion.expression.equal? self
            @return_type = nil
          ensure
            @return_type_recursion = false
          end
          raise CompilationError.new("Unlabeled recursion mixed with other labels.", rule) if @return_type.nil? and not create_return_type.nil?
        end
        @return_type
      end
      
      def create_return_type
        nil
      end
      
      def get_local_label(name)
        @parameters.each do |parameter|
          return parameter if parameter.name == name
        end
        @local_label_source ||= parent
        @local_label_source.get_local_label name
      end
      
      def has_local_value?
        false
      end
      
      def free_local_value(builder)
        # nothing to do
      end
      
      def all_mode_names
        @children.map(&:all_mode_names).flatten
      end
      
      def build_allocas(builder)
        @children.each { |child| child.build_allocas builder }
      end
      
      def mod=(mod)
        @mod = mod
        @fast_rule_function = nil
        @traced_rule_function = nil
      end
      
      def create_rule_functions(is_root_rule)
        return_llvm_type = LLVM::Pointer(return_type ? return_type.llvm_type : LLVM.Void)
        parameter_llvm_types = @parameters.map(&:value_type).map(&:llvm_type)
        
        @fast_rule_function = @mod.functions.add "#{@name}_fast", [LLVM_STRING, parser.mode_struct, return_llvm_type] + parameter_llvm_types, LLVM_STRING
        @fast_rule_function.linkage = :private
        @traced_rule_function = @mod.functions.add "#{@name}_traced", [LLVM_STRING, parser.mode_struct, return_llvm_type] + parameter_llvm_types, LLVM_STRING
        @traced_rule_function.linkage = :private
        if is_root_rule
          @rule_function = @mod.functions.add @name, [LLVM_STRING, LLVM_STRING, return_llvm_type], LLVM::Int1
          @rule_function.linkage = :external
        end
      end
      
      def build_rule_functions(is_root_rule)
        build_internal_rule_function false
        build_internal_rule_function true
        
        if is_root_rule
          builder = Builder.new
          entry_block = @rule_function.basic_blocks.append "rule_entry"
          successful_block = @rule_function.basic_blocks.append "rule_successful"
          failed_block = @rule_function.basic_blocks.append "rule_failed"
          
          builder.position_at_end entry_block
          start_ptr, end_ptr, return_value_ptr = @rule_function.params.to_a
          result = builder.call @fast_rule_function, start_ptr, parser.mode_struct.null, return_value_ptr
          successful = builder.icmp :eq, result, end_ptr
          builder.cond successful, successful_block, failed_block
          
          builder.position_at_end successful_block
          builder.ret LLVM::TRUE
          
          builder.position_at_end failed_block
          builder.call parser.free_value_functions[return_type.llvm_type], return_value_ptr if return_type
          builder.call @traced_rule_function, start_ptr, parser.mode_struct.null, return_value_ptr
          builder.call parser.free_value_functions[return_type.llvm_type], return_value_ptr if return_type
          builder.ret LLVM::FALSE
        end
      end
      
      def build_internal_rule_function(traced)
        function = traced ? @traced_rule_function : @fast_rule_function
        
        builder = Builder.new
        builder.parser = parser
        builder.traced = traced
        
        entry = function.basic_blocks.append "entry"
        builder.position_at_end entry
        build_allocas builder
        
        failed_block = builder.create_block "failed"
        @parameters.each_with_index do |parameter, index|
          parameter.value = function.params[index + 3]
        end
        end_result = build builder, function.params[0], function.params[1], failed_block
        
        builder.store end_result.return_value, function.params[2] if return_type
        builder.ret end_result.input
        
        builder.position_at_end failed_block
        builder.ret LLVM_STRING.null_pointer
        
        builder.dispose
      end
      
      def call_internal_rule_function(builder, *args)
        builder.call(builder.traced ? @traced_rule_function : @fast_rule_function, *args)
      end
      
      def match(input, options = {})
        parser.match_rule self, input, options
      end
      
      def free_value(value)
        return if return_type.nil?
        parser.execution_engine.run_function parser.free_value_functions[return_type.llvm_type], value
      end
          
      def eql?(other)
        self == other
      end
      
      def hash
        0 # no hash used for Array.uniq, always eql?
      end
    end
    
    class Parameter
      attr_reader :name
      attr_accessor :value
      
      def initialize(name)
        @name = name
      end
      
      def value_type
        InputRangeValueType::INSTANCE
      end
    end
    
    class EmptyParsingExpression < ParsingExpression
      def create_return_type
        nil
      end
      
      def build(builder, start_input, modes, failed_block)
        Result.new start_input
      end
    end
        
    class Primary < ParsingExpression
    end
  end
end