module JetPEG
  def self.realize_data_objects(data, class_scope)
    case data
    when Array
      data.map { |value| realize_data_objects value, class_scope }
    when Hash
      data.each_with_object({}) { |(key, value), h| h[key] = realize_data_objects value, class_scope }
    when DataInputRange
      data
    when DataObject
      data.create_object class_scope
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
    
    def create_object(class_scope)
      object_class = @class_name.inject(class_scope){ |scope, name| scope.const_get(name) }
      object_class.new JetPEG.realize_data_objects(@data, class_scope)
    end
  end
end