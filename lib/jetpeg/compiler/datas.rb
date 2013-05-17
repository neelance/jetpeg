module JetPEG
  module Compiler
    class StringData < ParsingExpression
      block :_entry do
        push_string @_builder.global_string_pointer(@_data[:string])
        br :_successful
      end
    end
    
    class BooleanData < ParsingExpression
      block :_entry do
        push_boolean (@_data[:value] ? LLVM::TRUE : LLVM::FALSE)
        br :_successful
      end
    end
    
    class HashData < ParsingExpression
      block :_entry do
        @_data[:entries].each do |entry|
          entry[:data].build @_builder, @_start_input, @_modes, @_blocks[:_failed]
          make_label @_builder.global_string_pointer(entry[:label])
        end
        merge_labels LLVM::Int64.from_i(@_data[:entries].size)
        br :_successful
      end
    end
    
    class ArrayData < ParsingExpression
      block :_entry do
        push_array LLVM::FALSE
        @_data[:entries].each do |entry|
          entry.build @_builder, @_start_input, @_modes, @_blocks[:_failed]
          append_to_array
        end
        br :_successful
      end
    end
    
    class ObjectData < ParsingExpression
      block :_entry do
        build :data, @_start_input, :_failed
        make_object @_builder.global_string_pointer(@_data[:class_name])
        br :_successful
      end
    end
    
    class LabelData < ParsingExpression
      block :_entry do
        read_from_source @_builder.global_string_pointer(@_data[:name])
        br :_successful
      end
    end
  end
end
