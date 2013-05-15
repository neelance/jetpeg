module JetPEG
  module Compiler
    class Label < ParsingExpression
      leftmost_leaves :child

      def build(builder, start_input, modes, failed_block)
        child_end_input, has_return_value = @data[:child].build builder, start_input, modes, failed_block
        
        if not has_return_value or data[:name] == "@"
          builder.call builder.output_functions[:pop] if has_return_value
          builder.call builder.output_functions[:push_input_range], start_input, child_end_input
        end

        if @data[:is_local]
          builder.call builder.output_functions[:locals_push]
        elsif data[:name] != "@"
          builder.call builder.output_functions[:make_label], builder.global_string_pointer(data[:name])
        end
        
        return child_end_input, !@data[:is_local]
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
      def build(builder, start_input, modes, failed_block)
        builder.call builder.output_functions[:locals_load], LLVM::Int64.from_i(get_local_label(@data[:name], 0))
        return start_input, true
      end
    end
    
    class ObjectCreator < ParsingExpression
      leftmost_leaves :child

      def build(builder, start_input, modes, failed_block)
        end_input, has_return_value = @data[:child].build builder, start_input, modes, failed_block
        builder.call builder.output_functions[:push_empty] if not has_return_value
        builder.call builder.output_functions[:set_as_source] if @data[:data]
        @data[:data].build builder, start_input, modes, failed_block if @data[:data]
        builder.call builder.output_functions[:make_object], builder.global_string_pointer(@data[:class_name])
        return end_input, true
      end
    end
    
    class ValueCreator < ParsingExpression
      leftmost_leaves :child

      def build(builder, start_input, modes, failed_block)
        end_input, has_return_value = @data[:child].build builder, start_input, modes, failed_block
        builder.call builder.output_functions[:push_empty] if not has_return_value
        builder.call builder.output_functions[:make_value], builder.global_string_pointer(@data[:code]), builder.global_string_pointer(parser.options[:filename]), LLVM::Int64.from_i(@data[:code].line)
        return end_input, true
      end
    end
  end
end