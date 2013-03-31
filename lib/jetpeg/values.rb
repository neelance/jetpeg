module JetPEG
  class ValueType
    attr_reader :llvm_type, :child_types
    
    def initialize(llvm_type, value_types)
      @llvm_type = llvm_type
      value_types << self
    end
    
    def all_labels
      []
    end
    
    def layout_types
      nil
    end
    
    def print_tree(indentation = 0)
      puts "#{'  ' * indentation} #{to_s}"
      child_types && child_types.each { |child| child.print_tree indentation + 1 }
    end
    
    def to_s
      self.class.to_s
    end
  end
  
  class InputRangeValueType < ValueType
    INSTANCE = new LLVM::Type.struct([LLVM_STRING, LLVM_STRING], false, self.name), []
    
    def all_labels
      [nil]
    end
  end
  
  class BooleanValueType < ValueType
    def initialize(value_types)
      super LLVM::Int64.type, value_types
    end
    
    def all_labels
      [nil]
    end
  end
  
  class StructValueType < ValueType
    attr_reader :layout_types
    
    def initialize(child_types, name, value_types)
      @child_layouts, @layout_types = process_types child_types
      
      llvm_type = LLVM::Type.struct(@layout_types.map(&:llvm_type), false, "#{self.class.name}_#{name}")
      super llvm_type, value_types
    end
  end
  
  class SequenceValueType < StructValueType
    attr_reader :child_layouts

    def process_types(child_types)
      child_layouts = {}
      layout_types = []
      child_types.each_with_index do |child_type, child_index|
        next if child_type.nil?
        if child_type.layout_types
          child_layouts[child_index] = [child_type, (layout_types.size...(layout_types.size + child_type.layout_types.size)).to_a]
          layout_types.concat child_type.layout_types
        else
          child_layouts[child_index] = [child_type, layout_types.size]
          layout_types << child_type
        end
      end
      [child_layouts, layout_types]
    end
    
    def all_labels
      @child_layouts.values.map(&:first).map(&:all_labels).flatten
    end
  end
  
  class ChoiceValueType < StructValueType
    SelectionFieldType = Struct.new(:llvm_type).new(LLVM::Int64)
    
    def process_types(child_types)
      child_layouts = {}
      layout_types = []
      layout_types << SelectionFieldType
      child_types.each_with_index do |child_type, child_index|
        next if child_type.nil?
        if child_type.layout_types
          index_array = []
          available_layout_types = layout_types.dup
          available_layout_types[0] = nil
          child_type.layout_types.each do |child_layout_type|
            layout_index = available_layout_types.index child_layout_type
            index_array << (layout_index || layout_types.size)
            layout_types << child_layout_type unless layout_index
            available_layout_types[layout_index] = nil if layout_index
          end
          child_layouts[child_index] = [child_type, index_array]
        else
          layout_index = layout_types.index child_type
          child_layouts[child_index] = [child_type, layout_index || layout_types.size]
          layout_types << child_type unless layout_index
        end
      end
      [child_layouts, layout_types]
    end
    
    def all_labels
      @child_layouts.values.map(&:first).map(&:all_labels).reduce(&:|)
    end
  end
  
  class PointerValueType < ValueType
    def initialize(target, value_types)
      @target = target
      @target_struct = LLVM::Type.struct(nil, false, self.class.name)
      super LLVM::Pointer(@target_struct), value_types
    end
    
    def all_labels
      []
    end
  end
  
  class ArrayValueType < ValueType
    attr_reader :return_type
    
    def initialize(entry_type, name, value_types)
      @entry_type = entry_type
      @child_types = [entry_type]
      @pointer_type = PointerValueType.new self, value_types
      @value_label_type = LabeledValueType.new entry_type, :value, value_types
      @previous_label_type = LabeledValueType.new(@pointer_type, :previous, value_types)
      @return_type = SequenceValueType.new([@value_label_type, @previous_label_type], name, value_types)
      super @pointer_type.llvm_type, value_types
    end
    
    def all_labels
      [nil]
    end
  end
  
  class WrappingValueType < ValueType
    attr_reader :inner_type
    
    def initialize(inner_type, value_types)
      super inner_type.llvm_type, value_types
      @inner_type = inner_type
      @child_types = [inner_type]
    end
    
    def layout_types
      @inner_type.layout_types
    end
  end
  
  class LabeledValueType < WrappingValueType
    def initialize(inner_type, name, value_types)
      super inner_type, value_types
      @name = name
    end
    
    def all_labels
      [@name]
    end
    
    def to_s
      "#{self.class.name}(#{@name})"
    end
  end
    
  class ObjectCreatorValueType < WrappingValueType
    def initialize(inner_type, class_name, data, value_types)
      super inner_type, value_types
      @class_name = class_name
      @data = data
    end
    
    def all_labels
      @inner_type ? [nil] : []
    end
  end
  
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
        @entries.reverse_each do |entry|
          entry.build builder
          builder.call builder.output_functions[:make_label], builder.global_string_pointer("value")
        end
        builder.call builder.output_functions[:push_nil]
        @entries.size.times do
          builder.call builder.output_functions[:make_label], builder.global_string_pointer("previous")
          builder.call builder.output_functions[:merge_labels], LLVM::Int64.from_i(2)
        end
        builder.call builder.output_functions[:make_array]
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
  
  class ValueCreatorValueType < WrappingValueType
    def initialize(inner_type, code, filename, line, value_types)
      super inner_type, value_types
      @code = code
      @filename = filename
      @line = line
    end
    
    def all_labels
      @inner_type ? [nil] : []
    end
  end
end
