module JetPEG
  def self.realize_data(data, class_scope = Object)
    case data
    when Array
      data.map { |value| realize_data value, class_scope }
    when Hash
      data.each_with_object({}) { |(key, value), h| h[key] = realize_data value, class_scope }
    when DataInputRange
      data
    when DataObject, DataValue
      data.realize class_scope
    when nil
      nil
    else
      raise ArgumentError, data.class
    end
  end
  
  class DataInputRange
    attr_reader :input, :position
    
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
    
    def method_missing(name, *args, &block)
      to_s.__send__(name, *args, &block)
    end
  end
  
  class DataObject
    def initialize(class_name, data)
      @class_name = class_name
      @data = data
    end
    
    def realize(class_scope)
      object_class = @class_name.inject(class_scope){ |scope, name| scope.const_get(name) }
      object_class.new JetPEG.realize_data(@data, class_scope)
    end
  end
  
  class DataValue
    class EvaluationScope
      def initialize(data)
        @data = data
      end
      
      def method_missing(name, *args)
        return @data[name] if @data.has_key? name
        super 
      end
    end
    
    def initialize(code, data)
      @code = code
      @data = data
    end
    
    def realize(class_scope)
      scope = EvaluationScope.new JetPEG.realize_data(@data, class_scope)
      scope.instance_eval @code
    end
  end
end