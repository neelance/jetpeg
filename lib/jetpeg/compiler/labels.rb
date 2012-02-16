module JetPEG
  module Compiler
    class Label < ParsingExpression
      attr_reader :label_name, :value
      
      def initialize(data)
        super
        @label_name = data[:name] && data[:name].to_sym
        @expression = data[:expression]
        self.children = [@expression]
        @is_local = data[:is_local]
        @capture_input = false
        @recursive = false
        @value_type = nil
        @value = nil
      end
      
      def value_type
        if @value_type.nil?
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
        end
        @value_type
      end

      def create_return_type
        return nil if @is_local
        HashValueType.new({ label_name => value_type }, "#{rule.name}_label")
      end
      
      def build(builder, start_input, failed_block)
        expresion_result = @expression.build builder, start_input, failed_block
        
        if @capture_input
          builder.build_free @expression.return_type, expresion_result.return_value if @expression.return_type
          @value = value_type.llvm_type.null
          @value = builder.insert_value @value, start_input, 0, "pos"
          @value = builder.insert_value @value, expresion_result.input, 1, "pos"
        elsif @recursive
          @value = value_type.store_value builder, expresion_result.return_value
        else
          @value = expresion_result.return_value
        end
        
        result = Result.new expresion_result.input
        result.return_value = HashValue.new builder, return_type, { label_name => value } unless @is_local
        result
      end
      
      def get_local_label(name)
        return self if @is_local and @label_name == name
        super
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
    
    class AtLabel < ParsingExpression
      def initialize(data)
        super
        @expression = data[:expression]
        self.children = [@expression]
        @capture_input = false
        @recursive = false
      end
      
      def create_return_type
        @label_type = begin
          @expression.return_type
        rescue Recursion
          @recursive = true
          rule.recursive_expressions << @expression
          PointerValueType.new @expression
        end
                
        if @label_type.nil?
          @label_type = InputRangeValueType::INSTANCE
          @capture_input = true
        end
        
        SingleValueType.new(@label_type)
      end
      
      def build(builder, start_input, failed_block)
        expresion_result = @expression.build builder, start_input, failed_block
        
        result = Result.new expresion_result.input
        if @capture_input
          value = @label_type.llvm_type.null
          value = builder.insert_value value, start_input, 0, "pos"
          value = builder.insert_value value, expresion_result.input, 1, "pos"
          result.return_value = value
        elsif @recursive
          result.return_value = @label_type.store_value builder, expresion_result.return_value
        else
          result.return_value = expresion_result.return_value
        end
        result
      end
    end
    
    class LocalValue < ParsingExpression
      def initialize(data)
        super
        @name = data[:name].to_sym
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
        
        result = Result.new start_input
        result.return_value = local_label.value
        result
      end
    end
    
    class ObjectCreator < AtLabel
      def initialize(data)
        super
        @class_name = data[:class_name].split("::").map(&:to_sym)
      end

      def create_return_type
        CreatorType.new super, __type__: :object, class_name: @class_name
      end
    end
    
    class ValueCreator < AtLabel
      def initialize(data)
        super
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