module JetPEG
  module Compiler
    class Label < ParsingExpression
      AT_SYMBOL = "@".to_sym
      
      attr_reader :label_name, :value_type, :value
      
      def initialize(data)
        super()
        @label_name = data[:name] && data[:name].to_sym
        @expression = data[:expression]
        self.children = [@expression]
        @is_local = data[:is_local]
        @capture_input = false
        @value_type = nil
        @value = nil
      end
      
      def create_return_type
        @value_type = begin
          @expression.return_type
        end
        
        if @value_type.nil? || label_name == AT_SYMBOL
          @capture_input = true
          @value_type = InputRangeValueType::INSTANCE
        end
        
        if @is_local
          nil
        elsif label_name.nil? || label_name == AT_SYMBOL
          @value_type
        else
          LabeledValueType.new @value_type, label_name, parser.value_types
        end
      end
      
      def build(builder, start_input, modes, failed_block)
        expression_result = @expression.build builder, start_input, modes, failed_block
        
        if @capture_input
          builder.call @expression.return_type.free_function, expression_result.return_value if @expression.return_type
          builder.call builder.output_functions[:pop] if @expression.return_type
          @value = @value_type.llvm_type.null
          @value = builder.insert_value @value, start_input, 0, "pos"
          @value = builder.insert_value @value, expression_result.input, 1, "pos"
          builder.call builder.output_functions[:push_input_range], start_input, expression_result.input
        else
          @value = expression_result.return_value
        end

        if return_type.is_a? LabeledValueType
          builder.call builder.output_functions[:make_label], builder.global_string_pointer(label_name.to_s)
        end
        
        Result.new expression_result.input, (@is_local ? nil : @value)
      end
      
      def get_local_label(name)
        return self if @is_local and @label_name == name
        super
      end
      
      def has_local_value?
        @is_local
      end
      
      def free_local_value(builder)
        builder.call @value_type.free_function, @value if @is_local
      end
    end
    
    class RuleCallLabel < Label
      def label_name
        @expression.referenced_name
      end
    end
    
    class LocalValue < ParsingExpression
      attr_reader :name
      attr_writer :local_label
      
      def initialize(data)
        super()
        @name = data[:name] && data[:name].to_sym
      end
      
      def local_label
        @local_label ||= get_local_label @name
        raise CompilationError.new("Undefined local value \"%#{name}\".", rule) if @local_label.nil?
        @local_label
      end
      
      def create_return_type
        local_label.value_type
      end
      
      def value
        local_label.value
      end
      
      def build(builder, start_input, modes, failed_block)
        builder.build_use_counter_increment local_label.value_type, local_label.value
        
        Result.new start_input, value
      end
    end
    
    class ObjectCreator < Label
      def initialize(data)
        super
        @class_name = data[:class_name]
        @data = data[:data]
      end

      def create_return_type
        ObjectCreatorValueType.new super, @class_name, @data, parser.value_types
      end
    end
    
    class ValueCreator < Label
      def initialize(data)
        super
        @code = data[:code]
      end

      def create_return_type
        ValueCreatorValueType.new super, @code, parser.filename, @code.line, parser.value_types
      end
    end
  end
end