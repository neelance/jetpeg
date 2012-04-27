module JetPEG
  class ValueType
    attr_reader :llvm_type, :ffi_type, :child_types, :free_function
    
    def initialize(llvm_type, ffi_type)
      @llvm_type = llvm_type
      @ffi_type = ffi_type
    end
    
    def all_labels
      [nil]
    end
    
    def load(output, pointer, input_address)
      data = ffi_type == :pointer ? pointer.get_pointer(0) : ffi_type.new(pointer)
      read output, data, input_address
    end
    
    def print_tree(indentation = 0)
      puts "#{'  ' * indentation} #{to_s}"
      child_types && child_types.each { |child| child.print_tree indentation + 1 }
    end
    
    def to_s
      self.class.to_s
    end
    
    def create_functions(mod)
      @free_function = mod.functions.add("free_value", [llvm_type], LLVM.Void())
    end
    
    def build_functions
      builder = Compiler::Builder.new
      builder.parser = $parser
      
      entry = @free_function.basic_blocks.append "entry"
      builder.position_at_end entry
      builder.build_free self, @free_function.params[0]
      builder.ret_void
      builder.dispose
    end
  end
  
  class InputRangeValueType < ValueType
    INSTANCE = new LLVM::Struct(LLVM_STRING, LLVM_STRING, self.name), Class.new(FFI::Struct).tap{ |s| s.layout(:begin, :pointer, :end, :pointer) }
    
    def read(output, data, input_address)
      output.new_input_range data[:begin].address - input_address, data[:end].address - input_address
    end
  end
  
  class ScalarValueType < ValueType
    def initialize
      super LLVM::Int64.type, :int64
    end
    
    def read(output, data, input_address)
      output.new_scalar data
    end
  end
  
  class StructValueType < ValueType
    attr_reader :layout_types
    
    def initialize(child_types, name)
      @child_types = child_types
      
      @type_indices = []
      @layout_types = []
      process_types
      
      llvm_type = LLVM::Struct(*@layout_types.map(&:llvm_type), "#{self.class.name}_#{name}")
      ffi_type = Class.new FFI::Struct
      ffi_layout = []
      @layout_types.each_with_index { |type, index| ffi_layout.push index.to_s.to_sym, type.ffi_type }
      ffi_type.layout(*ffi_layout)
      super llvm_type, ffi_type
    end
    
    def insert_value(builder, struct, value, index)
      type_index = @type_indices[index]
      if type_index.is_a? Array
        type_index.each_with_index do |target_index, source_index|
          struct = builder.insert_value struct, builder.extract_value(value, source_index), target_index
        end
      else
        struct = builder.insert_value struct, value, type_index
      end
      struct
    end
    
    def read_entry(output, data, index, input_address)
      type = @child_types[index]
      if type
        type_index = @type_indices[index]
        child_data = type_index.is_a?(Array) ? data.values_at(*type_index) : data[type_index]
        type.read output, child_data, input_address
      else
        output.new_nil
      end
    end
  end
  
  class SequenceValueType < StructValueType
    def process_types
      @child_types.each_with_index do |child_type, child_index|
        next if child_type.nil?
        child_type = child_type.inner_type while child_type.is_a? WrappingValueType
        if child_type.is_a? StructValueType
          @type_indices[child_index] = (@layout_types.size...(@layout_types.size + child_type.layout_types.size)).to_a
          @layout_types.concat child_type.layout_types
        else
          @type_indices[child_index] = @layout_types.size
          @layout_types << child_type
        end
      end
    end
    
    def read(output, data, input_address)
      data = data.values if data.is_a? FFI::Struct
      output.new_hash
      @child_types.each_index do |child_index|
        read_entry output, data, child_index, input_address
        output.merge_labels
      end
    end
    
    def all_labels
      @child_types.compact.map(&:all_labels).flatten
    end
  end
  
  class ChoiceValueType < StructValueType
    SelectionFieldType = Struct.new(:llvm_type, :ffi_type).new(LLVM::Int64, :int64)

    def process_types
      @layout_types << SelectionFieldType
      @child_types.each_with_index do |child_type, child_index|
        next if child_type.nil?
        child_type = child_type.inner_type while child_type.is_a? WrappingValueType
        if child_type.is_a? StructValueType
          index_array = []
          available_layout_types = @layout_types.dup
          available_layout_types[0] = nil
          child_type.layout_types.each do |child_layout_type|
            layout_index = available_layout_types.index child_layout_type
            index_array << (layout_index || @layout_types.size)
            @layout_types << child_layout_type unless layout_index
            available_layout_types[layout_index] = nil if layout_index
          end
          @type_indices[child_index] = index_array
        else
          layout_index = @layout_types.index child_type
          @type_indices[child_index] = layout_index || @layout_types.size
          @layout_types << child_type unless layout_index
        end
      end
    end
    
    def create_choice_value(builder, index, entry_result)
      struct = llvm_type.null
      struct = builder.insert_value struct, LLVM::Int64.from_i(index), 0
      struct = insert_value builder, struct, entry_result.return_value, index if entry_result.return_value
      struct
    end
    
    def read(output, data, input_address)
      data = data.values if data.is_a? FFI::Struct
      child_index = data.first
      read_entry output, data, child_index, input_address
    end
    
    def all_labels
      @child_types.compact.map(&:all_labels).reduce(&:|)
    end
  end
  
  class PointerValueType < ValueType
    def initialize(target)
      @target = target
      @target_struct = LLVM::Type.struct(nil, false, self.class.name)
      super LLVM::Pointer(@target_struct), :pointer
    end
    
    def realize
      @target_struct.element_types = [@target.return_type.llvm_type, LLVM::Int64] # [value, additional_use_counter]
    end
    
    def store_value(builder, value, begin_pos = nil, end_pos = nil)
      target_data = @target_struct.null
      target_data = builder.insert_value target_data, value, 0, "pointer_target_data"
      
      ptr = builder.malloc @target_struct
      builder.store target_data, ptr
      ptr
    end
    
    def read(output, data, input_address)
      if data.null?
        output.new_nil
        return
      end
      @target.return_type.load output, data, input_address # we can read directly, since the value is at the beginning of @target_struct
    end
  end
  
  class ArrayValueType < ValueType
    attr_reader :return_type
    
    def initialize(entry_type, name)
      @entry_type = entry_type
      @child_types = [entry_type]
      @pointer_type = PointerValueType.new self
      @return_type = SequenceValueType.new([LabeledValueType.new(entry_type, :value), LabeledValueType.new(@pointer_type, :previous)], name)
      @pointer_type.realize
      super @pointer_type.llvm_type, @pointer_type.ffi_type
    end
    
    def create_array_value(builder, entry_value, previous_entry)
      value = builder.create_struct @return_type.llvm_type
      value = @return_type.insert_value builder, value, entry_value, 0
      value = @return_type.insert_value builder, value, previous_entry, 1
      @pointer_type.store_value builder, value
    end
    
    def read(output, data, input_address)
      @pointer_type.read output, data, input_address
      output.make_array
    end
  end
  
  class WrappingValueType < ValueType
    attr_reader :inner_type
    
    def initialize(inner_type)
      super inner_type.llvm_type, inner_type.ffi_type
      @inner_type = inner_type
      @child_types = [inner_type]
    end
  end
  
  class LabeledValueType < WrappingValueType
    def initialize(inner_type, name)
      super inner_type
      @name = name
    end
    
    def all_labels
      [@name]
    end
    
    def read(output, data, input_address)
      @inner_type.read output, data, input_address
      output.set_label @name
    end
    
    def to_s
      "#{self.class.name}(#{@name})"
    end
  end
    
  class CreatorType < WrappingValueType
    def initialize(inner_type, creator_data = {})
      super inner_type
      @creator_data = creator_data
    end
    
    def read(output, data, input_address)
      @inner_type.read output, data, input_address
      output.make_object @creator_data
    end
  end
end
