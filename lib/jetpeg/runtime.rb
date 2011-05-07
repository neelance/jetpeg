module JetPEG
  class Parser
    attr_reader :mod, :malloc
    attr_accessor :class_scope
    
    def initialize(rules)
      @mod = LLVM::Module.create "Parser"
      @malloc = @mod.functions.add "malloc", [LLVM::Int], LLVM::Pointer(LLVM::Int8)
      @rules = rules
      rules.values.each do |rule|
        rule.parent = self
        rule.mod = mod
      end
      rules.values.each(&:rule_label_type) # trigger label type check
    end
    
    def [](name)
      @rules[name]
    end
    
    def parse(code)
      @rules.values.first.match code
    end
    
    def optimize!
      @rules.values.first.optimize!
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