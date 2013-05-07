module JetPEG
  module Compiler
    class ParsingExpression
      attr_accessor :data, :parent, :rule_name, :parameters, :is_root, :local_label_source, :all_mode_names
      
      def initialize(data)
        @data = data.is_a?(Hash) && data

        previous_child = nil
        @all_mode_names = []
        children.each do |child|
          child.parent = self
          child.local_label_source = previous_child
          previous_child = child
          @all_mode_names.concat child.all_mode_names
        end
        
        @rule_name = nil
        @parameters = []
        @is_root = false
        @rule_has_return_value = :pending
        @local_label_source = nil
      end
      
      def children
        (@data && @data[:child]) ? [@data[:child]] : []
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
      
      def rule_has_return_value?
        if @rule_has_return_value == :pending
          @rule_has_return_value = true # value for recursion
          internal_match_function false
        end
        @rule_has_return_value
      end
      
      def get_local_label(name, stack_index)
        @parameters.each_with_index do |parameter, param_index|
          return stack_index + param_index if parameter.name == name
        end
        @local_label_source ||= parent
        @local_label_source.get_local_label name, stack_index
      end
      
      def has_local_value?
        false
      end
      
      def free_local_value(builder)
        # nothing to do
      end

      def set_runtime(mod, mode_struct)
        @mod = mod
        @mode_struct = mode_struct
        @match_function = nil
        @internal_match_functions = {}
      end
      
      def match_function
        if @match_function.nil?
          @match_function = @mod.functions.add "#{@rule_name}_match", [LLVM_STRING, LLVM_STRING, LLVM::Int1, *OUTPUT_FUNCTION_POINTERS], LLVM::Int1
          @match_function.linkage = :external
        
          entry_block = @match_function.basic_blocks.append "rule_entry"
          successful_block = @match_function.basic_blocks.append "rule_successful"
          failed_block = @match_function.basic_blocks.append "rule_failed"
          start_ptr, end_ptr, force_traced, *output_functions = @match_function.params.to_a
          
          builder = Compiler::Builder.new
          builder.position_at_end entry_block
          not_traced_block = builder.create_block "not_traced"
          traced_block = builder.create_block "traced"
          builder.cond force_traced, traced_block, not_traced_block

          builder.position_at_end not_traced_block
          rule_end_input = builder.call internal_match_function(false), start_ptr, @mode_struct.null, *output_functions
          successful = builder.icmp :eq, rule_end_input, end_ptr
          builder.cond successful, successful_block, traced_block
          
          builder.position_at_end traced_block
          rule_end_input = builder.call internal_match_function(true), start_ptr, @mode_struct.null, *output_functions
          successful = builder.icmp :eq, rule_end_input, end_ptr
          builder.cond successful, successful_block, failed_block
          
          builder.position_at_end successful_block
          builder.ret LLVM::TRUE

          builder.position_at_end failed_block
          builder.ret LLVM::FALSE
          builder.dispose
        end
        @match_function
      end

      def internal_match_function(traced)
        if @internal_match_functions[traced].nil?
          function = @mod.functions.add "#{@rule_name}_internal_match", [LLVM_STRING, @mode_struct, *OUTPUT_FUNCTION_POINTERS], LLVM_STRING
          function.linkage = :private
          @internal_match_functions[traced] = function

          builder = Compiler::Builder.new
          entry_block = function.basic_blocks.append "entry"
          builder.traced = traced
          builder.rule_start_input = function.params[0]
          builder.output_functions = Hash[*OUTPUT_INTERFACE_SIGNATURES.keys.zip(function.params.to_a[2, OUTPUT_FUNCTION_POINTERS.size]).flatten]

          builder.position_at_end entry_block
          builder.direct_left_recursion_occurred = builder.alloca LLVM::Int1, "direct_left_recursion_occurred"
          builder.call builder.output_functions[:trace_enter], builder.global_string_pointer(@rule_name.to_s) if traced
          recursion_loop_block = builder.create_block "recursion_loop"
          builder.br recursion_loop_block

          builder.position_at_end recursion_loop_block
          builder.left_recursion_previous_end_input = builder.phi LLVM_STRING, { entry_block => LLVM_STRING.null }, "left_recursion_previous_end_input"
          builder.store LLVM::FALSE, builder.direct_left_recursion_occurred
          
          failed_block = builder.create_block "failed"
          end_input, @rule_has_return_value = build builder, function.params[0], function.params[1], failed_block
          
          direct_left_recursion_occurred_block = builder.create_block "direct_left_recursion_occurred"
          in_left_recursion_block = builder.create_block "in_left_recursion_block"
          left_recursion_not_finished_block = builder.create_block "left_recursion_not_finished"
          recursion_block = builder.create_block "recursion"
          no_recursion_block = builder.create_block "no_recursion"

          builder.cond builder.load(builder.direct_left_recursion_occurred, "direct_left_recursion_occurred"), direct_left_recursion_occurred_block, no_recursion_block

          builder.position_at_end direct_left_recursion_occurred_block
          in_left_recursion = builder.icmp :ne, builder.left_recursion_previous_end_input, LLVM_STRING.null, "in_left_recursion"
          builder.cond in_left_recursion, in_left_recursion_block, recursion_block

          builder.position_at_end in_left_recursion_block
          builder.call builder.output_functions[:locals_pop] if @rule_has_return_value
          left_recursion_finished = builder.icmp :eq, end_input, builder.left_recursion_previous_end_input, "left_recursion_finished"
          builder.cond left_recursion_finished, no_recursion_block, left_recursion_not_finished_block
          
          builder.position_at_end left_recursion_not_finished_block
          left_recursion_failed = builder.icmp :ult, end_input, builder.left_recursion_previous_end_input, "left_recursion_failed"
          builder.cond left_recursion_failed, failed_block, recursion_block

          builder.position_at_end recursion_block
          builder.call builder.output_functions[:locals_push] if @rule_has_return_value
          builder.left_recursion_previous_end_input.add_incoming recursion_block => end_input
          builder.br recursion_loop_block
          
          builder.position_at_end no_recursion_block
          builder.call builder.output_functions[:trace_leave], builder.global_string_pointer(@rule_name.to_s), LLVM::TRUE if traced
          builder.ret end_input
          
          builder.position_at_end failed_block
          builder.call builder.output_functions[:trace_leave], builder.global_string_pointer(@rule_name.to_s), LLVM::FALSE if traced
          builder.ret LLVM_STRING.null
          builder.dispose
        end
        @internal_match_functions[traced]
      end

      def ==(other)
        self.class == other.class && self.data == other.data
      end
      
      def eql?(other)
        self == other
      end
      
      def hash
        0 # no hash used for Array.uniq, always eql?
      end

      def get_leftmost_leaf
        nil
      end
      
      def replace_leftmost_leaf(replacement)
        raise
      end
    end
    
    class Parameter
      attr_reader :name
      attr_accessor :value
      
      def initialize(name)
        @name = name
      end
    end
    
    class EmptyParsingExpression < ParsingExpression
      def build(builder, start_input, modes, failed_block)
        return start_input, false
      end
    end
  end
end