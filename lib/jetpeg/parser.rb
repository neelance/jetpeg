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
    attr_accessor :root_rules, :failure_reason
    
    def initialize(rules)
      @rules = rules
      @rules.values.each { |rule| rule.parent = self }
      @mod = nil
      @root_rules = []
    end
    
    def verify!
      @rules.values.each(&:rule_label_type)
      @rules.values.each(&:realize_label_types)
    end
    
    def parser
      self
    end
    
    def [](name)
      @rules[name]
    end
    
    def match_rule(root_rule, input, raise_on_failure = true)
      if @mod.nil? or not @root_rules.include?(root_rule.name)
        @root_rules << root_rule.name
        
        @possible_failure_reasons = [] # needed to avoid GC
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
        
        @rules.values.each { |rule| rule.mod = @mod }
        
        @rules.values.each do |rule|
          linkage = @root_rules.include?(rule.name) ? :external : :private
          rule.rule_function(false).linkage = linkage
          rule.rule_function(true).linkage = linkage
        end
        
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
      data = root_rule.rule_label_type.ffi_type.new
      input_end_ptr = @execution_engine.run_function(root_rule.rule_function(false), input_ptr, data && data.pointer).to_value_ptr
      
      if input_end_ptr.null? or input_ptr.address + input.size != input_end_ptr.address
        @failure_reason = ParsingError.new([])
        @failure_reason_position = input_ptr
        @execution_engine.pointer_to_global(@llvm_add_failure_reason_callback).put_pointer 0, @ffi_add_failure_reason_callback
        @execution_engine.run_function(root_rule.rule_function(true), input_ptr, data && data.pointer)
        @failure_reason.input = input
        @failure_reason.position = @failure_reason_position.address - input_ptr.address
        raise @failure_reason if raise_on_failure
        return nil
      end
      
      root_rule.rule_label_type.read data, input, input_ptr.address
    end
    
    def parse(input)
      match_rule @rules.values.first, input
    end
  end
end