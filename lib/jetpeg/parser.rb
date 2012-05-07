verbose = $VERBOSE
$VERBOSE = false
require 'llvm/core'
require 'llvm/execution_engine'
require 'llvm/transforms/scalar'
require 'llvm/transforms/ipo'
$VERBOSE = verbose

LLVM.init_x86

module JetPEG
  class ParsingError < RuntimeError
    attr_reader :expectations, :other_reasons
    attr_accessor :position, :input
    
    def initialize(expectations, other_reasons = [])
      @expectations = expectations.uniq.sort
      @other_reasons = other_reasons.uniq.sort
    end
    
    def merge(other)
      ParsingError.new(@expectations + other.expectations, @other_reasons + other.other_reasons)
    end
    
    def to_s
      before = @input[0...@position]
      line = before.count("\n") + 1
      column = before.size - (before.rindex("\n") || 0)
      
      reasons = @other_reasons.dup
      reasons << "Expected one of #{@expectations.map{ |e| e.inspect[1..-2] }.join(", ")}" unless @expectations.empty?
      
      "At line #{line}, column #{column} (byte #{position}, after #{before[(before.size > 20 ? -20 : 0)..-1].inspect}): #{reasons.join(' / ')}."
    end
  end
  
  class OutputInterface
    attr_reader :stack
    
    def initialize(input, scalar_values)
      @input = input
      @scalar_values = scalar_values
      @stack = []
    end
    
    def new_nil
      @stack << nil
    end
        
    def new_input_range(from, to)
      @stack << { __type__: :input_range, input: @input, position: from...to }
    end
    
    def new_scalar(value)
      @stack << @scalar_values[value]
    end
    
    def make_label(name)
      value = @stack.pop
      @stack.push({ name => value })
    end
    
    def merge_labels(count)
      merged = @stack.pop(count).compact.reduce({}, &:merge)
      @stack.push merged
    end
    
    def make_array
      data = @stack.pop
      array = []
      until data.nil?
        array.unshift data[:value]
        data = data[:previous]
      end
      @stack.push array
    end
    
    def make_object(creator_data)
      data = @stack.pop
      @stack.push creator_data.merge({ data: data })
    end
  end
  
  class Parser
    @@default_options = { raise_on_failure: true, output: :realized, class_scope: ::Object, bitcode_optimization: false, machine_code_optimization: 0, track_malloc: false }
    
    def self.default_options
      @@default_options
    end
    
    attr_reader :filename, :mod, :execution_engine, :value_types, :mode_names, :mode_struct, :malloc_counter, :free_counter,
                :llvm_add_failure_reason_callback, :possible_failure_reasons, :scalar_values
    attr_accessor :root_rules, :failure_reason
    
    def initialize(rules, filename = "grammar")
      @rules = rules
      @rules.each_value { |rule| rule.parent = self }
      @mod = nil
      @execution_engine = nil
      @root_rules = [@rules.values.first.rule_name]
      @value_types = [InputRangeValueType::INSTANCE]
      @filename = filename
      @scalar_values = [nil]
      
      @rules.each_value(&:return_type) # calculate all return types
      @rules.each_value(&:realize_return_type) # realize recursive structures
    end
    
    def parser
      self
    end
    
    def get_local_label(name)
      nil
    end
    
    def [](name)
      @rules[name]
    end
    
    def scalar_value_for(scalar)
      index = @scalar_values.index(scalar)
      if index.nil?
        index = @scalar_values.size
        @scalar_values << scalar
      end
      LLVM::Int64.from_i index
    end
    
    def build(options = {})
      options.merge!(@@default_options) { |key, oldval, newval| oldval }

      if @execution_engine
        @execution_engine.dispose # disposes module, too
      end
      
      @possible_failure_reasons = []
      @mod = LLVM::Module.new "Parser"
      @mode_names = @rules.values.map(&:all_mode_names).flatten.uniq
      @mode_struct = LLVM::Struct(*([LLVM::Int1] * @mode_names.size), "mode_struct")
      
      if options[:track_malloc]
        @malloc_counter = @mod.globals.add LLVM::Int64, "malloc_counter"
        @malloc_counter.initializer = LLVM::Int64.from_i(0)
        @free_counter = @mod.globals.add LLVM::Int64, "free_counter"
        @free_counter.initializer = LLVM::Int64.from_i(0)
      else
        @malloc_counter = nil
        @free_counter = nil
      end
      
      @ffi_add_failure_reason_callback = FFI::Function.new(:void, [:bool, :pointer, :long]) do |failure, pos, reason_index|
        reason = @possible_failure_reasons[reason_index]
        if @failure_reason_position.address < pos.address
          @failure_reason = reason
          @failure_reason_position = pos
        elsif @failure_reason_position.address == pos.address
          @failure_reason = @failure_reason.merge reason
        end
      end
      
      add_failure_reason_callback_type = LLVM::Pointer(LLVM::Function([LLVM::Int1, LLVM_STRING, LLVM::Int], LLVM::Void()))
      @llvm_add_failure_reason_callback = LLVM::C.const_int_to_ptr LLVM::Int64.from_i(@ffi_add_failure_reason_callback.address), add_failure_reason_callback_type
      
      builder = Compiler::Builder.new
      builder.parser = self
      @rules.each_value { |rule| rule.create_functions @mod }
      @value_types.each { |type| type.create_functions @mod }
      @rules.each_value { |rule| rule.build_functions builder }
      @value_types.each { |type| type.build_functions builder }
      builder.dispose
      
      @mod.verify!
      @execution_engine = LLVM::JITCompiler.new @mod, options[:machine_code_optimization]
      
      if options[:bitcode_optimization]
        pass_manager = LLVM::PassManager.new @execution_engine # TODO tweak passes
        pass_manager.inline!
        pass_manager.mem2reg! # alternative: pass_manager.scalarrepl!
        pass_manager.instcombine!
        pass_manager.reassociate!
        pass_manager.gvn!
        pass_manager.simplifycfg!
        pass_manager.run @mod
      end
    end
    
    def each_expression(expressions = @rules.values, &block)
      expressions.each do |expression|
        block.call expression
        each_expression expression.children, &block
      end
    end
    
    def match_rule(root_rule, input, options = {})
      raise ArgumentError.new("Input must be a String.") if not input.is_a? String
      options.merge!(@@default_options) { |key, oldval, newval| oldval }
      
      if @mod.nil? or not @root_rules.include?(root_rule.rule_name)
        @root_rules << root_rule.rule_name
        build options
      end
      
      start_ptr = FFI::MemoryPointer.from_string input
      end_ptr = start_ptr + input.size
      value_ptr = root_rule.return_type && FFI::MemoryPointer.new(root_rule.return_type.ffi_type)
      
      @failure_reason = ParsingError.new([])
      @failure_reason_position = start_ptr
      
      success_value = @execution_engine.run_function root_rule.rule_function, start_ptr, end_ptr, value_ptr
      if not success_value.to_b
        success_value.dispose
        check_malloc_counter
        @failure_reason.input = input
        @failure_reason.position = @failure_reason_position.address - start_ptr.address
        raise @failure_reason if options[:raise_on_failure]
        return nil
      end
      success_value.dispose
      
      return [value_ptr, start_ptr.address] if options[:output] == :pointer
      
      intermediate = true 
      if value_ptr
        output = OutputInterface.new input, @scalar_values
        root_rule.return_type.load output, value_ptr, start_ptr.address
        intermediate = output.stack.first || true
        root_rule.free_value value_ptr if value_ptr
      end
      check_malloc_counter
      return intermediate if options[:output] == :intermediate

      realized = JetPEG.realize_data intermediate, options[:class_scope]
      return realized if options[:output] == :realized
      
      raise ArgumentError, "Invalid output option: #{options[:output]}"
    end
    
    def parse(input)
      match_rule @rules.values.first, input
    end
    
    def stats
      block_counts = @mod.functions.map { |f| f.basic_blocks.size }
      instruction_counts = @mod.functions.map { |f| f.basic_blocks.map { |b| b.instructions.to_a.size } }
      info = "#{@mod.functions.to_a.size} functions / #{block_counts.reduce(:+)} blocks / #{instruction_counts.flatten.reduce(:+)} instructions"
      if @malloc_counter
        malloc_count = @execution_engine.pointer_to_global(@malloc_counter).read_int64
        free_count = @execution_engine.pointer_to_global(@free_counter).read_int64
        info << "\n#{malloc_count} calls of malloc / #{free_count} calls of free"
      end
      info
    end
    
    def check_malloc_counter
      return if @malloc_counter.nil?
      malloc_count = @execution_engine.pointer_to_global(@malloc_counter).read_int64
      free_count = @execution_engine.pointer_to_global(@free_counter).read_int64
      raise "Internal error: Memory leak (#{malloc_count - free_count})." if malloc_count != free_count
    end
  end
end
