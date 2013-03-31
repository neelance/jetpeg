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
          @value_type = true
        end
        
        if @is_local
          nil
        elsif label_name.nil? || label_name == AT_SYMBOL
          @value_type
        else
          true
        end
      end
      
      def build(builder, start_input, modes, failed_block)
        expression_result = @expression.build builder, start_input, modes, failed_block
        
        if @capture_input
          builder.call builder.output_functions[:pop] if @expression.return_type
          builder.call builder.output_functions[:push_input_range], start_input, expression_result
        end

        if @is_local
          builder.call builder.output_functions[:store_local], LLVM::Int64.from_i(self.object_id)
        elsif not label_name.nil? and label_name != AT_SYMBOL
          builder.call builder.output_functions[:make_label], builder.global_string_pointer(label_name.to_s)
        end
        
        expression_result
      end
      
      def get_local_label(name)
        return self if @is_local and @label_name == name
        super
      end
      
      def has_local_value?
        @is_local
      end
      
      def free_local_value(builder)
        builder.call builder.output_functions[:delete_local], LLVM::Int64.from_i(self.object_id) if @is_local
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
      
      def build(builder, start_input, modes, failed_block)
        builder.call builder.output_functions[:load_local], LLVM::Int64.from_i(local_label.object_id)

        start_input
      end
    end
    
    class ObjectCreator < Label
      def initialize(data)
        super
        @class_name = data[:class_name]
        @data = data[:data]
      end

      def create_return_type
        super
        true
      end

      def build(builder, start_input, modes, failed_block)
        result = super
        if @data
          builder.call builder.output_functions[:set_as_source]
          @data.build builder
        end
        builder.call builder.output_functions[:make_object], builder.global_string_pointer(@class_name)
        result
      end
    end
    
    class ValueCreator < Label
      def initialize(data)
        super
        @code = data[:code]
      end

      def create_return_type
        super
        true
      end

      def build(builder, start_input, modes, failed_block)
        result = super
        builder.call builder.output_functions[:make_value], builder.global_string_pointer(@code), builder.global_string_pointer(parser.filename), LLVM::Int64.from_i(@code.line)
        result
      end
    end
  end
end