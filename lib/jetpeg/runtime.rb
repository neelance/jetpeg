module JetPEG
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
    
    def ==(other)
      to_s == other.to_s
    end
    
    def [](*args)
      to_s[*args]
    end
  end
end