module JetPEG
  module Compiler
    class ParsingExpression
      attr_accessor :parent, :rule_name, :parameters, :local_label_source
      
      def initialize
        @rule_name = nil
        @parameters = []
        @children = []
        @return_type = :pending
        @return_type_recursion = false
        @fast_match_function = nil
        @traced_match_function = nil
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
        @rule_name ? self : parent.rule
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
      
      def realize_return_type
        @children.map(&:realize_return_type)
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
      
      def rule_result_structure
        @rule_result_structure ||= LLVM::Type.struct([LLVM_STRING, return_type ? return_type.llvm_type : LLVM::Int8], true)
      end
      
      def create_functions(mod)
        parameter_llvm_types = @parameters.map(&:value_type).map(&:llvm_type)
        
        @fast_match_function = mod.functions.add "#{@rule_name}_fast_match", [LLVM_STRING, OUTPUT_FUNCTION_POINTERS.last, parser.mode_struct] + parameter_llvm_types, rule_result_structure
        @fast_match_function.linkage = :private
        @traced_match_function = mod.functions.add "#{@rule_name}_traced_match", [LLVM_STRING, OUTPUT_FUNCTION_POINTERS.last, parser.mode_struct] + parameter_llvm_types, rule_result_structure
        @traced_match_function.linkage = :private

        if parser.root_rules.include? @rule_name
          @match_function = mod.functions.add "#{@rule_name}_match", [LLVM_STRING, LLVM_STRING, *OUTPUT_FUNCTION_POINTERS], LLVM::Int1
          @match_function.linkage = :external
        end
      end
      
      def build_functions(builder)
        build_internal_rule_function false
        build_internal_rule_function true
        
        if parser.root_rules.include? @rule_name
          entry_block = @match_function.basic_blocks.append "rule_entry"
          successful_block = @match_function.basic_blocks.append "rule_successful"
          failed_block = @match_function.basic_blocks.append "rule_failed"
          start_ptr, end_ptr, *output_functions = @match_function.params.to_a
          
          builder.position_at_end entry_block
          rule_result = builder.call @fast_match_function, start_ptr, OUTPUT_FUNCTION_POINTERS.last.null, parser.mode_struct.null
          rule_end_input = builder.extract_value rule_result, 0
          return_value = builder.extract_value rule_result, 1
          successful = builder.icmp :eq, rule_end_input, end_ptr
          builder.cond successful, successful_block, failed_block
          
          builder.position_at_end successful_block
          builder.call return_type.read_function, return_value, *output_functions if return_type
          builder.call return_type.free_function, return_value if return_type
          builder.ret LLVM::TRUE
          
          builder.position_at_end failed_block
          builder.call return_type.free_function, return_value if return_type
          builder.call @traced_match_function, start_ptr, output_functions.last, parser.mode_struct.null
          builder.call return_type.free_function, return_value if return_type
          builder.ret LLVM::FALSE
        end
      end
      
      def build_internal_rule_function(traced)
        function = traced ? @traced_match_function : @fast_match_function
        
        builder = Builder.new
        builder.parser = parser
        builder.traced = traced
        builder.add_failure_callback = function.params[1]
        
        entry = function.basic_blocks.append "entry"
        builder.position_at_end entry
        
        failed_block = builder.create_block "failed"
        @parameters.each_with_index do |parameter, index|
          parameter.value = function.params[index + 3]
        end
        end_result = build builder, function.params[0], function.params[2], failed_block
        
        result = rule_result_structure.null
        result = builder.insert_value result, end_result.input, 0
        result = builder.insert_value result, end_result.return_value, 1 if return_type
        builder.ret result
        
        builder.position_at_end failed_block
        builder.ret rule_result_structure.null
        
        builder.dispose
      end
      
      def call_internal_match_function(builder, *args)
        builder.call(builder.traced ? @traced_match_function : @fast_match_function, *args)
      end
      
      def match(input, options = {})
        parser.match_rule @rule_name, input, options
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