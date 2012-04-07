module JetPEG
  module Compiler
    class RubySideStruct
      attr_reader :array
      
      def initialize(llvm_type)
        @llvm_type = llvm_type
        @array = Array.new llvm_type.element_types.size
      end
      
      def build(builder)
        data = @llvm_type.null
        @array.each_with_index do |value, index|
          data = builder.insert_value data, value, index, "hash_data_with_#{index}" if value
        end
        data
      end
    end
    
    class Builder
      remove_method :create_struct
      def create_struct(llvm_type)
        RubySideStruct.new llvm_type
      end
      
      def insert_value(aggregate, elem, index, name = "")
        elem = elem.build self if elem.is_a? RubySideStruct
        if aggregate.is_a? RubySideStruct
          aggregate.array[index] = elem
          return aggregate
        end
        super aggregate, elem, index, name
      end
      
      def extract_value(aggregate, index, name = "")
        return aggregate.array[index] if aggregate.is_a? RubySideStruct
        super
      end
      
      def store(val, pointer)
        val = val.build self if val.is_a? RubySideStruct
        super val, pointer
      end
    end
    
    class DynamicPhi
      alias_method :push_orig, :<<
      def <<(value)
        value = value.build @builder if value.is_a? RubySideStruct
        push_orig value
      end
    end
  end
end