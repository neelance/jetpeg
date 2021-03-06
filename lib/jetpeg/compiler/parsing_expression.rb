module JetPEG
  module Compiler
    class ParsingExpression
      attr_accessor :data, :parent, :rule_name, :parameters, :is_root, :local_label_source
      
      def initialize(data)
        @data = data || {}

        previous_child = nil
        children = []
        @data.values.each do |value|
          children << value if value.is_a? ParsingExpression
          children.concat value if value.is_a? Array and value[0].is_a? ParsingExpression
        end
        children.each do |child|
          child.parent = self
          child.local_label_source = previous_child
          previous_child = child
        end
        
        @rule_name = nil
        @parameters = []
        @is_root = false
        @rule_has_return_value = :pending
        @local_label_source = nil
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

      def set_runtime(mod)
        @mod = mod
        @match_function = nil
        @internal_match_functions = {}
      end
      
      def match_function
        if @match_function.nil?
          @match_function = @mod.functions.add "#{@rule_name}_match", [LLVM_STRING, LLVM_STRING, LLVM::Int1, *OUTPUT_FUNCTION_POINTERS], LLVM::Int1
          @match_function.linkage = :external
        
          entry_block      = @match_function.basic_blocks.append "rule_entry"
          successful_block = @match_function.basic_blocks.append "rule_successful"
          failed_block     = @match_function.basic_blocks.append "rule_failed"
          not_traced_block = @match_function.basic_blocks.append "not_traced"
          traced_block     = @match_function.basic_blocks.append "traced"
          
          builder = Compiler::Builder.new
          start_ptr, end_ptr, force_traced, *output_functions = @match_function.params.to_a

          builder.position_at_end entry_block
          builder.cond force_traced, traced_block, not_traced_block

          builder.position_at_end not_traced_block
          rule_end_input = builder.call internal_match_function(false), start_ptr, LLVM::Type.array(LLVM::Int1, 64).null, *output_functions
          successful = builder.icmp :eq, rule_end_input, end_ptr
          builder.cond successful, successful_block, traced_block
          
          builder.position_at_end traced_block
          rule_end_input = builder.call internal_match_function(true), start_ptr, LLVM::Type.array(LLVM::Int1, 64).null, *output_functions
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
          function = @mod.functions.add "#{@rule_name}_internal_match", [LLVM_STRING, LLVM::Type.array(LLVM::Int1, 64), *OUTPUT_FUNCTION_POINTERS], LLVM_STRING
          function.linkage = :private
          @internal_match_functions[traced] = function

          entry_block  = function.basic_blocks.append "entry"
          failed_block = function.basic_blocks.append "failed"

          builder = Compiler::Builder.new
          builder.parser = parser
          builder.function = function
          builder.traced = traced
          builder.rule_start_input = function.params[0]
          builder.output_functions = function.params.to_a[2, OUTPUT_FUNCTION_POINTERS.size]

          builder.position_at_end entry_block
          end_input, @rule_has_return_value = build builder, function.params[0], function.params[1], failed_block
          builder.ret end_input

          builder.position_at_end failed_block
          builder.ret LLVM_STRING.null

          builder.dispose
        end
        @internal_match_functions[traced]
      end

      @@blocks = Hash.new { |hash, key| hash[key] = {} }
      def self.block(name, &block)
        @@blocks[self][name] = block
      end

      def self.copy_blocks(from)
        @@blocks[self] = @@blocks[from]
      end

      def build(*args)
        BuildContext.new.generate self, @@blocks[self.class], @data, *args
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

      @@leftmost_leaves = Hash.new { |hash, key| hash[key] = [] }
      def self.leftmost_leaves(*names)
        @@leftmost_leaves[self] = names
      end

      def get_leftmost_leaf
        leaves = []
        @@leftmost_leaves[self.class].each do |name|
          return self if name == :self
          leaves << @data[name].get_leftmost_leaf
        end
        leaves.uniq.size == 1 ? leaves.first : nil
      end
      
      def replace_leftmost_leaf(replacement)
        @@leftmost_leaves[self.class].each do |name|
          return replacement if name == :self
          @data[name] = @data[name].replace_leftmost_leaf replacement
          @data[name].parent = self
        end
        self
      end
    end

    class BuildContext
      def generate(current, ruby_blocks, data, builder, start_input, modes, failed_block)
        @_current = current
        @_data = data
        @_start_input = start_input
        @_modes = modes
        @_has_return_value = false
        @_end_input = @_start_input

        @_builder = builder
        @_traced = builder.traced
        @_parser = builder.parser
        @_filename = builder.parser.options[:filename]
        @_rule_start_input = builder.rule_start_input
        @_direct_left_recursion_occurred = builder.direct_left_recursion_occurred
        @_left_recursion_previous_end_input = builder.left_recursion_previous_end_input
        @_output_functions = builder.output_functions

        @_blocks = {}
        ruby_blocks.each_key do |name|
          @_blocks[name] = @_builder.function.basic_blocks.append name.to_s
        end
        @_blocks[:_successful] ||= @_builder.function.basic_blocks.append "_successful"
        @_blocks[:_failed]     ||= @_builder.function.basic_blocks.append "_failed"
        @_end_blocks = @_blocks.dup

        @_builder.br @_blocks[:_entry]

        ruby_blocks.each do |name, ruby_block|
          @_builder.position_at_end @_blocks[name]
          instance_eval(&ruby_block)
          @_end_blocks[name] = @_builder.insert_block
        end

        @_builder.position_at_end @_blocks[:_failed]
        @_builder.br failed_block

        @_builder.position_at_end @_blocks[:_successful]
        return @_end_input, @_has_return_value
      end

      OUTPUT_INTERFACE_SIGNATURES.keys.each_with_index do |name, index|
        define_method name do |*args|
          @_builder.call @_builder.output_functions[index], *args
        end
      end

      LLVM::Builder.instance_methods(false).each do |name|
        define_method name do |*args|
          @_builder.__send__ name, *args
        end
      end

      def build(child_name, start_input, failed_block)
        @_data[child_name].build @_builder, start_input, @_modes, @_blocks[failed_block]
      end

      def build_all(child_name, start_input, failed_block)
        children = @_data[child_name]
        children.each { |c| c.build @_builder, start_input, @_modes, @_blocks[failed_block] } if children
      end

      def free_local_value(child_name)
        return if not @_data[child_name].data[:is_local]
        @_builder.call @_output_functions[OUTPUT_INTERFACE_SIGNATURES.keys.index(:locals_pop)], LLVM::Int64.from_i(1)
      end

      remove_method :br
      def br(block)
        @_builder.br @_blocks[block]
      end

      remove_method :cond
      def cond(value, true_block, false_block)
        @_builder.cond value, @_blocks[true_block], @_blocks[false_block]
      end

      remove_method :icmp
      def icmp(pred, lhs, rhs)
        @_builder.icmp pred, lhs, rhs
      end

      remove_method :phi
      def phi(type, branches)
        phi = @_builder.phi type, {}
        branches.each { |block, value| phi.add_incoming @_end_blocks[block] => value }
        phi
      end

      def add_incoming(phi, value)
        phi.add_incoming @_builder.insert_block => value
      end

      def unescape_char(value)
        if value[0] != "\\"
          value
        else
          case value[1]
          when "r" then "\r"
          when "n" then "\n"
          when "t" then "\t"
          when "0" then "\0"
          else value[1]
          end
        end
      end

      def character_byte(child_name)
        LLVM::Int8.from_i unescape_char(@_data[child_name]).ord
      end

      def i64(value)
        LLVM::Int64.from_i value
      end

      def string(value, unescape=false)
        value = @_data[value] if value.is_a? Symbol
        value = value.gsub(/\\./) { |c| unescape_char(c) } if unescape
        @_builder.global_string_pointer value
      end
    end
    
    class Rule < ParsingExpression
      block :_entry do
        @_builder.direct_left_recursion_occurred = alloca LLVM::Int1
        trace_enter string(@_current.rule_name.to_s) if @_traced
        br :recursion_loop
      end

      block :recursion_loop do
        @_builder.left_recursion_previous_end_input = phi LLVM_STRING, :_entry => LLVM_STRING.null
        store LLVM::FALSE, @_builder.direct_left_recursion_occurred
        @_end_input, @_has_return_value = build :child, @_start_input, :_failed
        cond load(@_builder.direct_left_recursion_occurred), :direct_left_recursion_occurred, :_successful
      end

      block :direct_left_recursion_occurred do
        @in_left_recursion = icmp :ne, @_builder.left_recursion_previous_end_input, LLVM_STRING.null
        cond @in_left_recursion, :in_left_recursion, :recursion
      end

      block :in_left_recursion do
        locals_pop i64(1) if @_has_return_value
        @left_recursion_finished = icmp :eq, @_end_input, @_builder.left_recursion_previous_end_input
        cond @left_recursion_finished, :_successful, :left_recursion_not_finished
      end
        
      block :left_recursion_not_finished do
        @left_recursion_failed = icmp :ult, @_end_input, @_builder.left_recursion_previous_end_input
        cond @left_recursion_failed, :_failed, :recursion
      end

      block :recursion do
        locals_push i64(1) if @_has_return_value
        add_incoming @_builder.left_recursion_previous_end_input, @_end_input
        br :recursion_loop
      end
        
      block :_successful do
        trace_leave string(@_current.rule_name.to_s), LLVM::TRUE if @_traced
      end
        
      block :_failed do
        trace_leave string(@_current.rule_name.to_s), LLVM::FALSE if @_traced
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
      block :_entry do
        br :_successful
      end
    end
  end
end