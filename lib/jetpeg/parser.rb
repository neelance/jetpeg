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
  
  class Parser
    @@default_options = { raise_on_failure: true, output: :realized, class_scope: ::Object, bitcode_optimization: false, machine_code_optimization: 0 }
    
    def self.default_options
      @@default_options
    end
    
    attr_reader :mod, :malloc, :free, :llvm_add_failure_reason_callback, :possible_failure_reasons, :scalar_value_type
    attr_accessor :root_rules, :failure_reason, :filename
    
    def initialize(rules)
      @rules = rules
      @rules.values.each { |rule| rule.parent = self }
      @mod = nil
      @root_rules = [@rules.values.first.name]
      @filename = "grammar"
      @scalar_values = [nil]
      @scalar_value_type = ScalarValueType.new @scalar_values
    end
    
    def verify!
      @rules.values.each(&:return_type)
      @rules.values.each(&:realize_recursive_return_types)
    end
    
    def parser
      self
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
      LLVM::Int index
    end
    
    def build(options = {})
      options.merge!(@@default_options) { |key, oldval, newval| oldval }
      
      @possible_failure_reasons = []
      @mod = LLVM::Module.new "Parser"
      @malloc = @mod.functions.add "malloc", [LLVM::Int64], LLVM::Pointer(LLVM::Int8)
      @free = @mod.functions.add "free", [LLVM::Pointer(LLVM::Int8)], LLVM.Void()
      @free_value_functions = {}
      
      add_failure_reason_callback_type = LLVM::Pointer(LLVM::Function([LLVM::Int1, LLVM_STRING, LLVM::Int], LLVM::Void()))
      @llvm_add_failure_reason_callback = @mod.globals.add add_failure_reason_callback_type, "add_failure_reason_callback"
      @llvm_add_failure_reason_callback.initializer = add_failure_reason_callback_type.null
      
      @ffi_add_failure_reason_callback = FFI::Function.new(:void, [:bool, :pointer, :long]) do |failure, pos, reason_index|
        reason = @possible_failure_reasons[reason_index]
        if @failure_reason_position.address < pos.address
          @failure_reason = reason
          @failure_reason_position = pos
        elsif @failure_reason_position.address == pos.address
          @failure_reason = @failure_reason.merge reason
        end
      end
      
      @rules.values.each { |rule| rule.mod = @mod }
      
      @rules.values.each do |rule|
        linkage = @root_rules.include?(rule.name) ? :external : :private
        rule.rule_function(false).linkage = linkage
        rule.rule_function(true).linkage = linkage
      end
      
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
        
    def match_rule(root_rule, input, options = {})
      raise ArgumentError.new("Input must be a String.") if not input.is_a? String
      options.merge!(@@default_options) { |key, oldval, newval| oldval }
      
      if @mod.nil? or not @root_rules.include?(root_rule.name)
        @root_rules << root_rule.name
        build options
      end
      
      args = []

      input_ptr = FFI::MemoryPointer.from_string input
      args << input_ptr

      value_pointer = nil
      unless root_rule.return_type.nil?
        value_pointer = FFI::MemoryPointer.new root_rule.return_type.ffi_type
        args << value_pointer
      end

      input_end_ptr = @execution_engine.run_function(root_rule.rule_function(false), *args).to_value_ptr
      
      if input_end_ptr.null? or input_ptr.address + input.size != input_end_ptr.address
        @failure_reason = ParsingError.new([])
        @failure_reason_position = input_ptr
        @execution_engine.pointer_to_global(@llvm_add_failure_reason_callback).put_pointer 0, @ffi_add_failure_reason_callback
        @execution_engine.run_function(root_rule.rule_function(true), *args)
        @failure_reason.input = input
        @failure_reason.position = @failure_reason_position.address - input_ptr.address
        raise @failure_reason if options[:raise_on_failure]
        return nil
      end
      
      return [value_pointer, input_ptr.address] if options[:output] == :pointer

      intermediate = value_pointer ? root_rule.return_type.load(value_pointer, input, input_ptr.address) : {}
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
      "#{@mod.functions.to_a.size} functions / #{block_counts.reduce(:+)} blocks / #{instruction_counts.flatten.reduce(:+)} instructions"
    end
  end
end
