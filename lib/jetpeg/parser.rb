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
    attr_reader :expectations
    attr_accessor :position, :input
    
    def initialize(expectations)
      @expectations = expectations.uniq.sort
    end
    
    def merge(other)
      ParsingError.new(@expectations + other.expectations)
    end
    
    def to_s
      before = @input[0...@position]
      line = before.count("\n") + 1
      column = before.size - before.rindex("\n")
      "At line #{line}, column #{column} (byte #{position}, after #{before[(before.size > 20 ? -20 : 0)..-1].inspect}): Expected one of #{expectations.map{ |e| e.inspect[1..-2] }.join(", ")}."
    end
  end
  
  class Parser
    @@default_options = { :raise_on_failure => true, :output => :realized, :class_scope => ::Object }
    
    def self.default_options
      @@default_options
    end
    
    attr_reader :mod, :malloc, :llvm_add_failure_reason_callback, :possible_failure_reasons
    attr_accessor :root_rules, :optimize, :failure_reason, :filename
    
    def initialize(rules)
      @rules = rules
      @rules.values.each { |rule| rule.parent = self }
      @mod = nil
      @root_rules = [@rules.values.first.name]
      @optimize = false
      @filename = "grammar"
    end
    
    def verify!
      @rules.values.each(&:rule_label_type)
      @rules.values.each(&:realize_label_types)
    end
    
    def parser
      self
    end
    
    def [](name)
      rule = @rules[name]
      raise CompilationError.new("Undefined rule \"#{name}\".") if rule.nil?
      rule
    end
    
    def build
      @possible_failure_reasons = [] # needed to avoid GC
      @mod = LLVM::Module.new "Parser"
      @malloc = @mod.functions.add "malloc", [LLVM::Int64], LLVM::Pointer(LLVM::Int8)
      
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
      @execution_engine = LLVM::JITCompiler.new @mod
      
      if @optimize
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
      @@default_options.each do |key, value|
        options[key] = value if not options.has_key? key
      end
      
      if @mod.nil? or not @root_rules.include?(root_rule.name)
        @root_rules << root_rule.name
        build
      end
      
      input_ptr = FFI::MemoryPointer.from_string input
      data_pointer = FFI::MemoryPointer.new root_rule.rule_label_type.ffi_type
      input_end_ptr = @execution_engine.run_function(root_rule.rule_function(false), input_ptr, data_pointer).to_value_ptr
      
      if input_end_ptr.null? or input_ptr.address + input.size != input_end_ptr.address
        @failure_reason = ParsingError.new([])
        @failure_reason_position = input_ptr
        @execution_engine.pointer_to_global(@llvm_add_failure_reason_callback).put_pointer 0, @ffi_add_failure_reason_callback
        @execution_engine.run_function(root_rule.rule_function(true), input_ptr, data_pointer)
        @failure_reason.input = input
        @failure_reason.position = @failure_reason_position.address - input_ptr.address
        raise @failure_reason if options[:raise_on_failure]
        return nil
      end
      
      return [data_pointer, input_ptr.address] if options[:output] == :pointer

      intermediate = root_rule.rule_label_type.load data_pointer, input, input_ptr.address
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
