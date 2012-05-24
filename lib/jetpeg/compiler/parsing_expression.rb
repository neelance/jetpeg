module JetPEG
  module Compiler
    class ParsingExpression
      attr_accessor :parent, :rule_name, :parameters, :local_label_source, :has_direct_recursion
      
      def initialize
        @rule_name = nil
        @parameters = []
        @children = []
        @return_type = :pending
        @return_type_recursion = false
        @internal_match_functions = {}
        @local_label_source = nil
        @has_direct_recursion = false
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
          raise Recursion.new if @return_type_recursion
          begin
            @return_type_recursion = true
            @return_type = create_return_type
          ensure
            @return_type_recursion = false
          end
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
      
      def rule_result_structure
        @rule_result_structure ||= LLVM::Type.struct([LLVM_STRING, return_type ? return_type.llvm_type : LLVM::Int8], true)
      end
      
      def create_functions(mod, is_root_rule, mode_struct)
        parameter_llvm_types = @parameters.map(&:value_type).map(&:llvm_type)
        
        [false, true].repeated_permutation(2) do |traced, is_left_recursion|
          next if is_left_recursion and not @has_direct_recursion
          function = mod.functions.add "#{@rule_name}_internal_match", [LLVM_STRING, OUTPUT_FUNCTION_POINTERS.last, mode_struct] + parameter_llvm_types + (is_left_recursion ? [rule_result_structure] : []), rule_result_structure
          function.linkage = :private
          @internal_match_functions[[traced, is_left_recursion]] = function
        end

        if is_root_rule
          @match_function = mod.functions.add "#{@rule_name}_match", [LLVM_STRING, LLVM_STRING, *OUTPUT_FUNCTION_POINTERS], LLVM::Int1
          @match_function.linkage = :external
        end
      end
      
      def build_functions(builder, is_root_rule, mode_struct)
        @internal_match_functions.each do |(traced, is_left_recursion), function|
          entry = function.basic_blocks.append "entry"
          builder.position_at_end entry
  
          builder.traced = traced
          builder.is_left_recursion = is_left_recursion
          builder.rule_start_input = function.params[0]
          builder.add_failure_callback = function.params[1]
          builder.left_recursion_occurred = builder.alloca LLVM::Int1
          builder.store LLVM::FALSE, builder.left_recursion_occurred
          builder.left_recursion_last_result = function.params[-1]
          
          failed_block = builder.create_block "failed"
          @parameters.each_with_index do |parameter, index|
            parameter.value = function.params[index + 3]
          end
          end_result = build builder, function.params[0], function.params[2], failed_block
          
          result = rule_result_structure.null
          result = builder.insert_value result, end_result.input, 0
          result = builder.insert_value result, end_result.return_value, 1 if return_type
          
          if @has_direct_recursion
            if is_left_recursion
              finished = builder.icmp :eq, end_result.input, builder.extract_value(builder.left_recursion_last_result, 0), "left_recursion_finished"
              left_recursion_finished_block, left_recursion_not_finished_block = builder.cond finished
              
              builder.position_at_end left_recursion_finished_block
              builder.ret result
              
              builder.position_at_end left_recursion_not_finished_block
              recursion_result = builder.call @internal_match_functions[[traced, true]], *function.params.to_a[0..-2], result
              builder.call return_type.free_function, end_result.return_value
              builder.ret recursion_result
            else
              left_recursion_occurred_block, no_left_recursion_occurred_block = builder.cond builder.load(builder.left_recursion_occurred, "left_recursion_occurred")
              
              builder.position_at_end left_recursion_occurred_block
              recursion_result = builder.call @internal_match_functions[[traced, true]], *function.params, result
              builder.call return_type.free_function, end_result.return_value
              builder.ret recursion_result
              
              builder.position_at_end no_left_recursion_occurred_block
              builder.ret result
            end
          else
            builder.ret result
          end
          
          builder.position_at_end failed_block
          builder.ret rule_result_structure.null
        end
        
        if is_root_rule
          entry_block = @match_function.basic_blocks.append "rule_entry"
          successful_block = @match_function.basic_blocks.append "rule_successful"
          failed_block = @match_function.basic_blocks.append "rule_failed"
          start_ptr, end_ptr, *output_functions = @match_function.params.to_a
          
          builder.position_at_end entry_block
          rule_result = builder.call @internal_match_functions[[false, false]], start_ptr, OUTPUT_FUNCTION_POINTERS.last.null, mode_struct.null
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
          rule_result = builder.call @internal_match_functions[[true, false]], start_ptr, output_functions.last, mode_struct.null
          return_value = builder.extract_value rule_result, 1
          builder.call return_type.free_function, return_value if return_type
          builder.ret LLVM::FALSE
        end
      end
      
      def get_internal_match_function(traced, is_left_recursion)
        @internal_match_functions[[traced, is_left_recursion]]
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