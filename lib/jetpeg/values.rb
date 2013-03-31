module JetPEG

  module Compiler
    class StringData
      def initialize(data)
        @string = data
      end
      
      def build(builder)
        builder.call builder.output_functions[:push_string], builder.global_string_pointer(@string)
      end
    end
    
    class BooleanData
      def initialize(data)
        @value = data[:value]
      end
      
      def build(builder)
        builder.call builder.output_functions[:push_boolean], (@value ? LLVM::TRUE : LLVM::FALSE)
      end
    end
    
    class HashData
      def initialize(data)
        @entries = data[:entries]
      end
      
      def build(builder)
        @entries.each do |entry|
          entry[:data].build builder
          builder.call builder.output_functions[:make_label], builder.global_string_pointer(entry[:label])
        end
        builder.call builder.output_functions[:merge_labels], LLVM::Int64.from_i(@entries.size)
      end
    end
    
    class ArrayData
      def initialize(data)
        @entries = data[:entries]
      end
      
      def build(builder)
        builder.call builder.output_functions[:push_array], LLVM::FALSE
        @entries.each do |entry|
          entry.build builder
          builder.call builder.output_functions[:append_to_array]
        end
      end
    end
    
    class ObjectData
      def initialize(data)
        @class_name = data[:class_name]
        @data = data[:data]
      end
      
      def build(builder)
        @data.build builder
        builder.call builder.output_functions[:make_object], builder.global_string_pointer(@class_name)
      end
    end
    
    class LabelData
      def initialize(data)
        @name = data
      end
      
      def build(builder)
        builder.call builder.output_functions[:read_from_source], builder.global_string_pointer(@name)
      end
    end
  end

end
