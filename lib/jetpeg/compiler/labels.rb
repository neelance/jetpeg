module JetPEG
  module Compiler
    class Label < ParsingExpression
      def initialize(data)
        super
        @expression = data[:child]
        self.children = [@expression]
      end
      
      def calculate_has_return_value?
        !@data[:is_local]
      end
      
      def build(builder, start_input, modes, failed_block)
        expression_end_input = @expression.build builder, start_input, modes, failed_block
        
        if not @expression.has_return_value? or data[:name] == "@"
          builder.call builder.output_functions[:pop] if @expression.has_return_value?
          builder.call builder.output_functions[:push_input_range], start_input, expression_end_input
        end

        if @data[:is_local]
          builder.call builder.output_functions[:locals_push]
        elsif data[:name] != "@"
          builder.call builder.output_functions[:make_label], builder.global_string_pointer(data[:name])
        end
        
        expression_end_input
      end
      
      def get_local_label(name, stack_index)
        if @data[:is_local]
          return stack_index if data[:name] == name
          return super name, stack_index + 1
        end
        super name, stack_index
      end
      
      def has_local_value?
        @data[:is_local]
      end
      
      def free_local_value(builder)
        builder.call builder.output_functions[:locals_pop] if @data[:is_local]
      end
    end
    
    class RuleCallLabel < Label
      def initialize(data)
        super name: data[:child].data[:name], child: data[:child]
      end
    end
    
    class LocalValue < ParsingExpression
      def calculate_has_return_value?
        true
      end
      
      def build(builder, start_input, modes, failed_block)
        index = get_local_label @data[:name], 0
        raise CompilationError.new("Undefined local value \"%#{@data[:name]}\".", rule) if index.nil?
        builder.call builder.output_functions[:locals_load], LLVM::Int64.from_i(index)
        start_input
      end
    end
    
    class ObjectCreator < ParsingExpression
      def initialize(data)
        super
        @expression = data[:child]
        self.children = [@expression]
      end

      def calculate_has_return_value?
        true
      end

      def build(builder, start_input, modes, failed_block)
        end_input = @expression.build builder, start_input, modes, failed_block
        builder.call builder.output_functions[:push_nil] if not @expression.has_return_value?
        if @data[:data]
          builder.call builder.output_functions[:set_as_source]
          @data[:data].build builder
        end
        builder.call builder.output_functions[:make_object], builder.global_string_pointer(@data[:class_name])
        end_input
      end
    end
    
    class ValueCreator < ParsingExpression
      def initialize(data)
        super
        @expression = data[:child]
        self.children = [@expression]
      end

      def calculate_has_return_value?
        true
      end

      def build(builder, start_input, modes, failed_block)
        end_input = @expression.build builder, start_input, modes, failed_block
        builder.call builder.output_functions[:push_nil] if not @expression.has_return_value?
        builder.call builder.output_functions[:make_value], builder.global_string_pointer(@data[:code]), builder.global_string_pointer(parser.filename), LLVM::Int64.from_i(@data[:code].line)
        end_input
      end
    end
  end
end