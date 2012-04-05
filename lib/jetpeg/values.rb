module JetPEG
  class ValueType
    attr_reader :llvm_type, :ffi_type, :child_types
    
    def initialize(llvm_type, ffi_type)
      @llvm_type = llvm_type
      @ffi_type = ffi_type
    end
    
    def all_labels
      [nil]
    end
    
    def load(pointer, input, input_address, values)
      return nil if pointer.null?
      data = ffi_type == :pointer ? pointer.get_pointer(0) : ffi_type.new(pointer)
      read data, input, input_address, values
    end
    
    def alloca(builder, name)
      builder.alloca llvm_type, name
    end
    
    def eql?(other)
      self == other
    end
    
    def hash
      0 # no hash used for Array.uniq, always eql?
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
    INSTANCE = new LLVM::Struct(LLVM_STRING, LLVM_STRING, "input_range"), Class.new(FFI::Struct).tap{ |s| s.layout(:begin, :pointer, :end, :pointer) }
    
    def read(data, input, input_address, values)
      return nil if data[:begin].null?
      { __type__: :input_range, input: input, position: (data[:begin].address - input_address)...(data[:end].address - input_address) }
    end
  end
  
  class ScalarValueType < ValueType
    attr_reader :scalar_values
    
    def initialize(scalar_values)
      super LLVM::Int32, :int32
      @scalar_values = scalar_values
    end
    
    def read(data, input, input_address, values)
      @scalar_values[data]
    end
    
    def ==(other)
      other.is_a?(ScalarValueType) && other.scalar_values.equal?(@scalar_values)
    end
  end
  
  class LabeledValueType < ValueType
    attr_reader :type, :name
    
    def initialize(type, name)
      super type.llvm_type, type.ffi_type
      @type = type
      @child_types = [@type]
      @name = name
    end
    
    def all_labels
      [@name]
    end
    
    def read(data, input, input_address, values)
      values[@name] = @type.read data, input, input_address, {}
      values
    end
    
    def ==(other)
      other.is_a?(LabeledValueType) && other.type == @type && other.name == @name
    end
    
    def to_s
      "#{self.class.to_s}(#{@name})"
    end
  end
    
  class StructValueType < ValueType
    def initialize(child_types, name)
      @child_types = child_types
      
      llvm_type = LLVM::Struct(*@child_types.map(&:llvm_type), "#{name}_struct")
      ffi_type = Class.new FFI::Struct
      ffi_layout = []
      child_types.each_with_index { |type, index| ffi_layout.push index.to_s.to_sym, type.ffi_type }
      ffi_type.layout(*ffi_layout)
      
      super llvm_type, ffi_type
    end
    
    def all_labels
      @child_types.map(&:all_labels).flatten
    end
    
    def read(data, input, input_address, values)
      @child_types.each_with_index do |type, index|
        values = type.read data[index.to_s.to_sym], input, input_address, values
      end
      values
    end

    def ==(other)
      other.is_a?(StructValueType) && other.child_types == @child_types
    end
  end
  
  class ChoiceValueType < ValueType
    attr_reader :name

    def initialize(child_types, name)
      @child_types = child_types
      @name = name
      
      llvm_layout = []
      ffi_layout = []
      @child_types.each_with_index do |type, index|
        next if type.nil?
        llvm_layout.push type.llvm_type
        ffi_layout.push index.to_s.to_sym, type.ffi_type
      end
      llvm_type = LLVM::Struct(LLVM::Int32, *llvm_layout, "#{name}_struct") # TODO memory optimization with "union" structure and bitcasts
      ffi_type = Class.new FFI::Struct
      ffi_type.layout(:selection, :int32, *ffi_layout)
      super llvm_type, ffi_type
    end
    
    def all_labels
      @child_types.map(&:all_labels).reduce(&:|)
    end
    
    def read(data, input, input_address, values)
      type = @child_types[data[:selection]]
      type && type.read(data[data[:selection].to_s.to_sym], input, input_address, values)
    end
    
    def ==(other)
      other.is_a?(ChoiceValueType) && other.types == @child_types
    end
  end
  
  class PointerValueType < ValueType
    attr_reader :target
    
    def initialize(target)
      @target = target
      @target_struct = LLVM::Struct("pointer_target")
      @target_struct_realized = false
      super LLVM::Pointer(@target_struct), :pointer
    end
    
    def realize_target_struct
      return if @target_struct_realized
      @target_struct.element_types = [@target.return_type.llvm_type, LLVM::Int] # [value, additional_use_counter]
      @target_struct_realized = true
    end
    
    def store_value(builder, value, begin_pos = nil, end_pos = nil)
      realize_target_struct
      target_data = @target_struct.null
      target_data = builder.insert_value target_data, value, 0, "pointer_target_data"
      
      ptr = builder.malloc @target_struct
      builder.store target_data, ptr
      ptr
    end
    
    def read(data, input, input_address, values)
      return nil if data.null?
      target_type = @target.return_type
      target_type.load data, input, input_address, values # we can read directly, since the value is at the beginning of @target_struct
    end
    
    def ==(other)
      other.is_a?(PointerValueType) && other.target == @target
    end
  end
  
  class ArrayValueType < ValueType
    attr_reader :entry_type, :return_type
    
    def initialize(entry_type, name)
      @entry_type = entry_type
      @child_types = [entry_type]
      @pointer_type = PointerValueType.new self
      @return_type = StructValueType.new([LabeledValueType.new(entry_type, :value), LabeledValueType.new(@pointer_type, :previous)], name)
      super @pointer_type.llvm_type, @pointer_type.ffi_type
    end
    
    def create_entry(builder, result, previous_entry)
      value = builder.create_struct @return_type.llvm_type
      value = builder.insert_value value, result.return_value, 0
      value = builder.insert_value value, previous_entry, 1
      @pointer_type.store_value builder, value
    end
    
    def read(data, input, input_address, values)
      array = []
      data = @pointer_type.read data, input, input_address, {}
      until data.nil?
        array.unshift data[:value]
        data = data[:previous]
      end
      array
    end
    
    def ==(other)
      other.is_a?(ArrayValueType) && other.entry_type == @entry_type
    end
  end
    
  class CreatorType < ValueType
    attr_reader :creator_data, :data_type
    
    def initialize(data_type, creator_data = {})
      @data_type = data_type
      @child_types = [data_type]
      @creator_data = creator_data
      super @data_type.llvm_type, @data_type.ffi_type
    end
    
    def read(data, input, input_address, values)
      result = @creator_data.clone
      result[:data] = @data_type.read data, input, input_address, {}
      result
    end
    
    def ==(other)
      other.is_a?(CreatorType) && other.creator_data == @creator_data && other.data_type == @data_type
    end
  end
end
