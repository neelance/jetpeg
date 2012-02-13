module JetPEG
  class ValueType
    attr_reader :llvm_type, :ffi_type
    
    def initialize(llvm_type, ffi_type)
      @llvm_type = llvm_type
      @ffi_type = ffi_type
    end
    
    def alloca(builder, name)
      builder.alloca llvm_type, name
    end
    
    def read_value(builder, data)
      data
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
  
  class SingleValueType < ValueType
    attr_reader :type
    
    def initialize(type)
      super type.llvm_type, type.ffi_type
      @type = type
    end
    
    def read(data, input, input_address)
      @type.read data, input, input_address
    end
    
    def ==(other)
      other.is_a?(SingleValueType) && other.type == @type
    end
  end
  
  class HashValue < Hash
    #attr_reader :type
    
    def initialize(builder, hash_type, hash = nil)
      @builder = builder
      @hash_type = hash_type
      @ptr = nil
      self.merge! hash if hash
    end
    
    def to_ptr
      data = @hash_type.llvm_type.null
      self.each do |name, entry|
        data = @builder.insert_value data, entry, @hash_type.struct_keys.index(name), "hash_data_with_#{name}" if entry
      end
      data.to_ptr
    end
    
    def type
      @hash_type.llvm_type
    end
  end

  class HashValueType < ValueType
    attr_reader :types, :struct_keys
    
    def initialize(types, value_name)
      @types = types
      @types_with_data = @types.select { |key, value| value.llvm_type }
      @struct_keys = @types_with_data.keys
      
      llvm_type = LLVM::Struct(*@types_with_data.values.map(&:llvm_type), "#{value_name}_struct")
      ffi_type = Class.new FFI::Struct
      ffi_type.layout(*@types_with_data.map{ |name, type| [name, type.ffi_type] }.flatten)
      
      super llvm_type, ffi_type
    end
    
    def read_value(builder, data)
      value = HashValue.new builder, self
      @types_with_data.keys.each_with_index do |name, index|
         value[name] = builder.extract_value(data, index, name.to_s)
      end
      value
    end
    
    def read(data, input, input_address)
      values = {}
      @types.each do |name, type|
        values[name] = type.read(type.llvm_type && data[name], input, input_address)
      end
      values
    end

    def ==(other)
      other.is_a?(HashValueType) && other.types == @types
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
      @target_struct.element_types = [@target.return_type.llvm_type]
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
      target_data = target_type.ffi_type == :pointer ? data.get_pointer(0) : target_type.ffi_type.new(data)
      target_type.read target_data, input, input_address
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
      @return_type = HashValueType.new({ value: entry_type, previous: @pointer_type }, name)
      super @pointer_type.llvm_type, @pointer_type.ffi_type
    end
    
    def create_entry(builder, value, previous_entry)
      value = HashValue.new builder, @entry_type, value if @entry_type.is_a? HashValueType
      @pointer_type.store_value builder, HashValue.new(builder, @return_type, { value: value, previous: previous_entry })
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
