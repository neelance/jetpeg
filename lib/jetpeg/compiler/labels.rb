module JetPEG
  module Compiler
    class Label < ParsingExpression
      AT_SYMBOL = "@".to_sym
      
      attr_reader :label_name
      
      def initialize(data)
        super()
        @label_name = data[:name] && data[:name].to_sym
        @expression = data[:expression]
        self.children = [@expression]
        @is_local = data[:is_local]
      end
      
      def calculate_has_return_value
        !@is_local
      end
      
      def build(builder, start_input, modes, failed_block)
        expression_end_input = @expression.build builder, start_input, modes, failed_block
        
        if not @expression.has_return_value or label_name == AT_SYMBOL
          builder.call builder.output_functions[:pop] if @expression.has_return_value
          builder.call builder.output_functions[:push_input_range], start_input, expression_end_input
        end

        if @is_local
          builder.call builder.output_functions[:store_local], LLVM::Int64.from_i(self.object_id)
        elsif not label_name.nil? and label_name != AT_SYMBOL
          builder.call builder.output_functions[:make_label], builder.global_string_pointer(label_name.to_s)
        end
        
        expression_end_input
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
      
      def calculate_has_return_value
        true
      end
      
      def build(builder, start_input, modes, failed_block)
        builder.call builder.output_functions[:load_local], LLVM::Int64.from_i(local_label.object_id)

        start_input
      end
    end
    
    class ObjectCreator < ParsingExpression
      def initialize(data)
        super()
        @expression = data[:expression]
        self.children = [@expression]
        @class_name = data[:class_name]
        @data = data[:data]
      end

      def calculate_has_return_value
        true
      end

      def build(builder, start_input, modes, failed_block)
        end_input = @expression.build builder, start_input, modes, failed_block
        builder.call builder.output_functions[:push_nil] if not @expression.has_return_value
        if @data
          builder.call builder.output_functions[:set_as_source]
          @data.build builder
        end
        builder.call builder.output_functions[:make_object], builder.global_string_pointer(@class_name)
        end_input
      end
    end
    
    class ValueCreator < ParsingExpression
      def initialize(data)
        super()
        @expression = data[:expression]
        self.children = [@expression]
        @code = data[:code]
      end

      def calculate_has_return_value
        true
      end

      def build(builder, start_input, modes, failed_block)
        end_input = @expression.build builder, start_input, modes, failed_block
        builder.call builder.output_functions[:push_nil] if not @expression.has_return_value
        builder.call builder.output_functions[:make_value], builder.global_string_pointer(@code), builder.global_string_pointer(parser.filename), LLVM::Int64.from_i(@code.line)
        end_input
      end
    end
  end
end