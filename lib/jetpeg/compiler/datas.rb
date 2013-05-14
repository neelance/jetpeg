module JetPEG
  module Compiler
    class StringData < ParsingExpression
      def build(builder, start_input, modes, failed_block)
        builder.call builder.output_functions[:push_string], builder.global_string_pointer(@data)
      end
    end
    
    class BooleanData < ParsingExpression
      def build(builder, start_input, modes, failed_block)
        builder.call builder.output_functions[:push_boolean], (@data[:value] ? LLVM::TRUE : LLVM::FALSE)
      end
    end
    
    class HashData < ParsingExpression
      def build(builder, start_input, modes, failed_block)
        @data[:entries].each do |entry|
          entry[:data].build builder, start_input, modes, failed_block
          builder.call builder.output_functions[:make_label], builder.global_string_pointer(entry[:label])
        end
        builder.call builder.output_functions[:merge_labels], LLVM::Int64.from_i(@data[:entries].size)
      end
    end
    
    class ArrayData < ParsingExpression
      def build(builder, start_input, modes, failed_block)
        builder.call builder.output_functions[:push_array], LLVM::FALSE
        @data[:entries].each do |entry|
          entry.build builder, start_input, modes, failed_block
          builder.call builder.output_functions[:append_to_array]
        end
      end
    end
    
    class ObjectData < ParsingExpression
      def build(builder, start_input, modes, failed_block)
        @data[:data].build builder, start_input, modes, failed_block
        builder.call builder.output_functions[:make_object], builder.global_string_pointer(@data[:class_name])
      end
    end
    
    class LabelData < ParsingExpression
      def build(builder, start_input, modes, failed_block)
        builder.call builder.output_functions[:read_from_source], builder.global_string_pointer(@data)
      end
    end
  end
end
