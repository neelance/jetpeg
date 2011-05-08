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
    attr_reader :mod, :malloc, :llvm_add_failure_reason_callback, :possible_failure_reasons
    attr_accessor :class_scope, :failure_reason
    
    def initialize(rules)
      @mod = LLVM::Module.create "Parser"
      @malloc = @mod.functions.add "malloc", [LLVM::Int], LLVM::Pointer(LLVM::Int8)
      
      add_failure_reason_callback_type = LLVM::Pointer(LLVM::Function([LLVM::Int1, LLVM_STRING, LLVM::Int], LLVM::Void()))
      @llvm_add_failure_reason_callback = @mod.globals.add add_failure_reason_callback_type, "add_failure_reason_callback"
      @llvm_add_failure_reason_callback.initializer = add_failure_reason_callback_type.null
      
      @ffi_add_failure_reason_callback = FFI::Function.new(:void, [:bool, :pointer, :long]) do |failure, pos, reason_id|
        reason = ObjectSpace._id2ref reason_id
        if @failure_reason_position.address < pos.address
          @failure_reason = reason
          @failure_reason_position = pos
        elsif @failure_reason_position.address == pos.address
          @failure_reason = @failure_reason.merge reason
        end
      end
      
      @rules = rules
      rules.values.each do |rule|
        rule.parent = self
        rule.mod = mod
      end
      rules.values.each(&:rule_label_type) # trigger label type check

      @current_rule = nil
      @possible_failure_reasons = [] # needed to avoid GC
    end
    
    def [](name)
      @rules[name]
    end
    
    def match_rule(rule, input, raise_on_failure = true)
      if rule != @current_rule
        @current_rule = rule
        
        rule.rule_function(false).linkage = :external
        rule.rule_function(true).linkage = :external
        @mod.verify!
        
        @execution_engine = LLVM::ExecutionEngine.create_jit_compiler @mod
        pass_manager = LLVM::PassManager.new @execution_engine # TODO tweak passes
        pass_manager.inline!
        pass_manager.instcombine!
        pass_manager.reassociate!
        pass_manager.gvn!
        pass_manager.simplifycfg!
        pass_manager.run @mod
      end
      
      input_ptr = FFI::MemoryPointer.from_string input
      data = rule.rule_label_type.ffi_type.new
      input_end_ptr = @execution_engine.run_function(rule.rule_function(false), input_ptr, data && data.pointer).to_value_ptr
      
      if input_end_ptr.null? or input_ptr.address + input.size != input_end_ptr.address
        @failure_reason = ParsingError.new([])
        @failure_reason_position = input_ptr
        @execution_engine.pointer_to_global(@llvm_add_failure_reason_callback).put_pointer 0, @ffi_add_failure_reason_callback
        @execution_engine.run_function(rule.rule_function(true), input_ptr, data && data.pointer)
        @possible_failure_reasons.clear
        @failure_reason.input = input
        @failure_reason.position = @failure_reason_position.address - input_ptr.address
        raise @failure_reason if raise_on_failure
        return nil
      end
      
      rule.rule_label_type.read data, input, input_ptr.address, @class_scope
    end
    
    def parse(input)
      match_rule @rules.values.first, input
    end
  end
    
  class InputRange
    attr_reader :position
    
    def initialize(input, position)
      @input = input
      @position = position
    end
    
    def to_s
      @text ||= @input[@position]
    end
    alias_method :to_str, :to_s
    
    def inspect
      to_s.inspect
    end
    
    def ==(other)
      to_s == other.to_s
    end
    
    def [](*args)
      to_s[*args]
    end
  end
end