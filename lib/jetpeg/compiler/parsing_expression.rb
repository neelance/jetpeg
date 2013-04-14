module JetPEG
  module Compiler
    class ParsingExpression
      attr_accessor :data, :parent, :rule_name, :parameters, :is_root, :local_label_source, :has_direct_recursion
      attr_reader :children
      
      def initialize(data)
        @data = data
        children = []
        children << data[:child] if data and data[:child]
        children.concat data[:children] if data and data[:children]
        self.children = children

        previous_child = nil
        @children.each do |child|
          child.local_label_source = previous_child
          previous_child = child
        end
        
        @rule_name = nil
        @parameters = []
        @is_root = false
        @has_return_value = :pending
        @has_return_value_recursion = false
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
      
      def has_return_value?
        if @has_return_value == :pending
          raise Recursion.new if @has_return_value_recursion
          begin
            @has_return_value_recursion = true
            @has_return_value = calculate_has_return_value?
          ensure
            @has_return_value_recursion = false
          end
        end
        @has_return_value
      end
      
      def calculate_has_return_value?
        false
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
      
      def all_mode_names
        @children.map(&:all_mode_names).flatten
      end

      def set_runtime(mod, mode_struct)
        @mod = mod
        @mode_struct = mode_struct
        @match_function = nil
        @internal_match_functions = {}
      end
      
      def match_function
        if @match_function.nil?
          @match_function = @mod.functions.add "#{@rule_name}_match", [LLVM_STRING, LLVM_STRING, *OUTPUT_FUNCTION_POINTERS], LLVM::Int1
          @match_function.linkage = :external
        
          entry_block = @match_function.basic_blocks.append "rule_entry"
          successful_block = @match_function.basic_blocks.append "rule_successful"
          failed_block = @match_function.basic_blocks.append "rule_failed"
          start_ptr, end_ptr, *output_functions = @match_function.params.to_a
          
          builder = Compiler::Builder.new
          builder.position_at_end entry_block
          rule_end_input = builder.call internal_match_function(false), start_ptr, @mode_struct.null, *output_functions, LLVM_STRING.null
          successful = builder.icmp :eq, rule_end_input, end_ptr
          builder.cond successful, successful_block, failed_block
          
          builder.position_at_end successful_block
          builder.ret LLVM::TRUE
          
          builder.position_at_end failed_block
          builder.call internal_match_function(true), start_ptr, @mode_struct.null, *output_functions, LLVM_STRING.null
          builder.ret LLVM::FALSE
          builder.dispose
        end
        @match_function
      end

      def internal_match_function(traced)
        if @internal_match_functions[traced].nil?
          function = @mod.functions.add "#{@rule_name}_internal_match", [LLVM_STRING, @mode_struct, *OUTPUT_FUNCTION_POINTERS, LLVM_STRING], LLVM_STRING
          function.linkage = :private
          @internal_match_functions[traced] = function

          entry = function.basic_blocks.append "entry"
          builder = Compiler::Builder.new
          builder.position_at_end entry
          builder.traced = traced
          builder.rule_start_input = function.params[0]
          builder.output_functions = Hash[*OUTPUT_INTERFACE_SIGNATURES.keys.zip(function.params.to_a[2, OUTPUT_FUNCTION_POINTERS.size]).flatten]
          builder.left_recursion_occurred = builder.alloca LLVM::Int1
          builder.store LLVM::FALSE, builder.left_recursion_occurred
          builder.left_recursion_previous_end_input = function.params[-1]
          
          failed_block = builder.create_block "failed"
          end_input = build builder, function.params[0], function.params[1], failed_block
          
          if @has_direct_recursion
            recursion_block = builder.create_block "recursion"
            no_recursion_block = builder.create_block "no_recursion"

            in_left_recursion = builder.icmp :ne, builder.left_recursion_previous_end_input, LLVM_STRING.null, "in_left_recursion"
            in_left_recursion_block, not_in_left_recursion_block = builder.cond in_left_recursion

            builder.position_at_end in_left_recursion_block
            left_recursion_finished = builder.icmp :eq, end_input, builder.left_recursion_previous_end_input, "left_recursion_finished"
            left_recursion_not_finished_block = builder.create_block "left_recursion_not_finished"
            builder.cond left_recursion_finished, no_recursion_block, left_recursion_not_finished_block
            
            builder.position_at_end left_recursion_not_finished_block
            left_recursion_failed = builder.icmp :ult, end_input, builder.left_recursion_previous_end_input, "left_recursion_failed"
            builder.cond left_recursion_failed, failed_block, recursion_block

            builder.position_at_end not_in_left_recursion_block
            builder.cond builder.load(builder.left_recursion_occurred, "left_recursion_occurred"), recursion_block, no_recursion_block

            builder.position_at_end recursion_block
            recursion_end_input = builder.call internal_match_function(traced), *function.params.to_a[0..-2], end_input
            builder.ret recursion_end_input
            
            builder.position_at_end no_recursion_block
            builder.ret end_input
          else
            builder.ret end_input
          end
          
          builder.position_at_end failed_block
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

      def is_primary
        false
      end

      def get_leftmost_primary
        if @children.empty?
          nil
        elsif @children.first.is_primary
          @children.first
        else
          @children.first.get_leftmost_primary
        end
      end
      
      def replace_leftmost_primary(replacement)
        if @children.empty?
          raise
        elsif @children.first.is_primary
          @children[0] = replacement
          @expression = replacement
          replacement.parent = self
        else
          @children.first.replace_leftmost_primary replacement
        end
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
      def initialize(data = nil)
        super
      end
      
      def build(builder, start_input, modes, failed_block)
        start_input
      end
    end
  end
end