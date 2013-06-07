module JetPEG
  module Compiler
    class StringData < ParsingExpression
      block :_entry do
        push_string string(:string)
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
        build_all :entries, @_start_input, :_failed
        merge_labels LLVM::Int64.from_i(@_data[:entries].size)
        br :_successful
      end
    end

    class HashDataEntry < ParsingExpression
      block :_entry do
        build :data, @_start_input, :_failed
        make_label string(:label)
        br :_successful
      end
    end
    
    class ArrayData < ParsingExpression
      block :_entry do
        push_array LLVM::FALSE
        build_all :entries, @_start_input, :_failed
        br :_successful
      end
    end
    
    class ArrayDataEntry < ParsingExpression
      block :_entry do
        build :data, @_start_input, :_failed
        append_to_array
        br :_successful
      end
    end
    
    class ObjectData < ParsingExpression
      block :_entry do
        build :data, @_start_input, :_failed
        make_object string(:class_name)
        br :_successful
      end
    end
    
    class LabelData < ParsingExpression
      block :_entry do
        read_from_source string(:name)
        br :_successful
      end
    end
  end
end
