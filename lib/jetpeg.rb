require "jetpeg/compiler"

module JetPEG
  def self.load(file)
    Compiler.compile_grammar IO.read(file)
  end
  
  class EvaluationScope
    def initialize(data)
      @data = data
    end
    
    def method_missing(name, *args)
      return @data[name] if @data.has_key? name
      super 
    end
  end
    
  def self.realize_data(data, class_scope = Object)
    case data
    when Hash
      case data[:$type]
      when :input_range
        data[:input][data[:position]]
      when :object
        object_class = data[:class_name].inject(class_scope) { |scope, name| scope.const_get(name) }
        object_class.new realize_data(data[:data], class_scope)
      when :value
        scope = EvaluationScope.new realize_data(data[:data], class_scope)
        scope.instance_eval data[:code]
      else
        data.each_with_object({}) { |(key, value), h| h[key] = realize_data value, class_scope }
      end
    when Array
      data.map { |value| realize_data value, class_scope }
    else
      data
    end
  end
end