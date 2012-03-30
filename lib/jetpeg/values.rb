module JetPEG
  class ValueType
    attr_reader :llvm_type, :ffi_type
    
    def initialize(llvm_type, ffi_type)
      @llvm_type = llvm_type
      @ffi_type = ffi_type
    end
    
    def all_labels
      [nil]
    end
    
    def load(pointer, input, input_address)
      return nil if pointer.null?
      data = ffi_type == :pointer ? pointer.get_pointer(0) : ffi_type.new(pointer)
      read data, input, input_address
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
  end
  
  class InputRangeValueType < ValueType
    INSTANCE = new LLVM::Struct(LLVM_STRING, LLVM_STRING, "input_range"), Class.new(FFI::Struct).tap{ |s| s.layout(:begin, :pointer, :end, :pointer) }
    
    def read(data, input, input_address)
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
    
    def read(data, input, input_address)
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
      @name = name
    end
    
    def all_labels
      [@name]
    end
    
    def read_value(values, data, input, input_address)
      values[@name] = @type.read data, input, input_address
    end
    
    def ==(other)
      other.is_a?(LabeledValueType) && other.type == @type && other.name == @name
    end
  end
    
  class StructValueType < ValueType
    attr_reader :types
    
    def initialize(types, name)
      @types = types
      
      llvm_type = LLVM::Struct(*@types.map(&:llvm_type), "#{name}_struct")
      ffi_type = Class.new FFI::Struct
      ffi_layout = []
      types.each_with_index { |type, index| ffi_layout.push index.to_s.to_sym, type.ffi_type }
      ffi_type.layout(*ffi_layout)
      
      super llvm_type, ffi_type
    end
    
    def all_labels
      @types.map(&:all_labels).flatten
    end
    
    def create_value(builder, data = [])
      struct_value = builder.create_struct llvm_type
      data.each_with_index do |value, index|
        struct_value = builder.insert_value struct_value, value, index
      end
      struct_value
    end
    
    def read(data, input, input_address)
      values = {}
      @types.each_with_index do |type, index|
        type.read_value(values, data[index.to_s.to_sym], input, input_address)
      end
      values
    end

    def read_value(values, data, input, input_address)
      @types.each_with_index do |type, index|
        type.read_value(values, data[index.to_s.to_sym], input, input_address)
      end
    end

    def ==(other)
      false #other.is_a?(StructValueType) && other.types == @types
    end
  end
  
  class ChoiceValueType < ValueType
    attr_reader :reduced_types

    def initialize(types, name)
      @all_types = types
      @reduced_types = types.compact.uniq
      @name = name
      
      return super @reduced_types.first.llvm_type, @reduced_types.first.ffi_type if @reduced_types.size == 1

      llvm_layout = []
      ffi_layout = []
      @reduced_types.each_with_index do |type, index|
        next if type.llvm_type.nil?
        llvm_layout.push type.llvm_type
        ffi_layout.push index.to_s.to_sym, type.ffi_type
      end
      llvm_type = LLVM::Struct(LLVM::Int32, *llvm_layout, "#{name}_struct") # TODO memory optimization with "union" structure and bitcasts
      ffi_type = Class.new FFI::Struct
      ffi_type.layout(:selection, :int32, *ffi_layout)
      super llvm_type, ffi_type
    end
    
    def all_labels
      @all_types.map(&:all_labels).reduce(&:|)
    end
    
    def create_choice_value(builder, all_types_index, value)
      return value if @reduced_types.size == 1

      reduced_types_index = @reduced_types.index @all_types[all_types_index]
      return nil if reduced_types_index.nil?
      
      data = llvm_type.null
      data = builder.insert_value data, LLVM::Int(reduced_types_index), 0, "choice_data_with_index"
      data = builder.insert_value data, value, reduced_types_index + 1, "choice_data_with_#{@name}" if value
      data
    end
    
    def read(data, input, input_address)
      return @reduced_types.first.read data, input, input_address if @reduced_types.size == 1

      type = @reduced_types[data[:selection]]
      type.read(type.llvm_type && data[data[:selection].to_s.to_sym], input, input_address)
    end
    
    def read_value(values, data, input, input_address)
      return @reduced_types.first.read_value, values, data, input, input_address if @reduced_types.size == 1

      type = @reduced_types[data[:selection]]
      type.read_value(values, type.llvm_type && data[data[:selection].to_s.to_sym], input, input_address)
    end
    
    def ==(other)
      other.is_a?(ChoiceValueType) && other.reduced_types == @reduced_types
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
    
    def read(data, input, input_address)
      return nil if data.null?
      target_type = @target.return_type
      target_type.load data, input, input_address # we can read directly, since the value is at the beginning of @target_struct
    end
    
    def ==(other)
      other.is_a?(PointerValueType) && other.target == @target
    end
  end
  
  class ArrayValueType < ValueType
    attr_reader :entry_type, :return_type
    
    def initialize(entry_type, name)
      @entry_type = entry_type
      @pointer_type = PointerValueType.new self
      @return_type = StructValueType.new([LabeledValueType.new(entry_type, :value), LabeledValueType.new(@pointer_type, :previous)], name)
      super @pointer_type.llvm_type, @pointer_type.ffi_type
    end
    
    def create_entry(builder, result, previous_entry)
      #if @entry_type.is_a? StructValueType # remap
      #  value = @entry_type.create_value builder
      #  result.return_type.types.keys.each_with_index do |key, index|
      #    elem = builder.extract_value result.return_value, index
      #    value = builder.insert_value value, elem, @entry_type.types.keys.index(key)
      #  end
      #else
        value = result.return_value
      #end
      @pointer_type.store_value builder, @return_type.create_value(builder, [value, previous_entry])
    end
    
    def read(data, input, input_address)
      array = []
      data = @pointer_type.read data, input, input_address
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
      @creator_data = creator_data
      super @data_type.llvm_type, @data_type.ffi_type
    end
    
    def read(data, input, input_address)
      result = @creator_data.clone
      result[:data] = @data_type.read(data, input, input_address)
      result
    end
    
    def ==(other)
      other.is_a?(CreatorType) && other.creator_data == @creator_data && other.data_type == @data_type
    end
  end
end
