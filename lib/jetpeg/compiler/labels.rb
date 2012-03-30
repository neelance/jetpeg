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
        @recursive = false
        @value_type = nil
        @value = nil
      end
      
      def create_return_type
         @value_type = begin
          @expression.return_type
        rescue Recursion
          @recursive = true
          rule.recursive_expressions << @expression
          PointerValueType.new @expression
        end
        
        if @value_type.nil?
          @value_type = InputRangeValueType::INSTANCE
          @capture_input = true
        end
        
        if @is_local
          nil
        elsif @label_name == AT_SYMBOL
          @value_type
        else
          StructValueType.new([LabeledValueType.new(@value_type, label_name)], "#{rule.name}_label")
        end
      end
      
      def build(builder, start_input, failed_block)
        expression_result = @expression.build builder, start_input, failed_block
        
        if @capture_input
          builder.build_free @expression.return_type, expression_result.return_value if @expression.return_type
          @value = @value_type.llvm_type.null
          @value = builder.insert_value @value, start_input, 0, "pos"
          @value = builder.insert_value @value, expression_result.input, 1, "pos"
        elsif @recursive
          @value = @value_type.store_value builder, expression_result.return_value
        else
          @value = expression_result.return_value
        end
        
        return_value = if @is_local
          nil
        elsif @label_name == AT_SYMBOL
          @value
        else
          return_type.create_value builder, [value]
        end
        Result.new expression_result.input, return_type, return_value
      end
      
      def get_local_label(name)
        return self if @is_local and @label_name == name
        super
      end
      
      def has_local_value?
        @is_local
      end
      
      def free_local_value(builder)
        builder.build_free value_type, @value if @is_local
      end
    end
    
    class RuleNameLabel < Label
      def label_name
        @expression.referenced_name
      end
    end
    
    class LocalValue < ParsingExpression
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
      
      def build(builder, start_input, failed_block)
        builder.build_use_counter_increment local_label.value_type, local_label.value
        
        Result.new start_input, return_type, local_label.value
      end
    end
    
    class ObjectCreator < Label
      def initialize(data)
        super
        @label_name = AT_SYMBOL
        @class_name = data[:class_name].split("::").map(&:to_sym)
      end

      def create_return_type
        CreatorType.new super, __type__: :object, class_name: @class_name
      end
    end
    
    class ValueCreator < Label
      def initialize(data)
        super
        @label_name = AT_SYMBOL
        @code = data[:code]
        input_range = data.intermediate[:code]
        @lineno = input_range[:input][0, input_range[:position].begin].count("\n") + 1
      end

      def create_return_type
        CreatorType.new super, __type__: :value, code: @code, filename: parser.filename, lineno: @lineno
      end
    end
  end
end