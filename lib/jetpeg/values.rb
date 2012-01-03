module JetPEG
  class ValueType
    attr_reader :llvm_type, :ffi_type
    
    def initialize(llvm_type, ffi_type)
      @llvm_type = llvm_type
      @ffi_type = ffi_type
    end
    
    def load(pointer, input, input_address)
      return nil if pointer.null?
      data = ffi_type == :pointer ? pointer.get_pointer(0) : ffi_type.new(pointer)
      read data, input, input_address
    end
    
    def alloca(builder, name)
      builder.alloca llvm_type, name
    end
    
    def create_llvm_value(builder, value, begin_pos = nil, end_pos = nil)
      value
    end
    
    def read_value(builder, data)
      data
    end
  end
  
  class InputRangeValueType < ValueType
    INSTANCE = new LLVM::Struct(LLVM_STRING, LLVM_STRING), Class.new(FFI::Struct).tap{ |s| s.layout(:begin, :pointer, :end, :pointer) }
    
    def create_llvm_value(builder, value, begin_pos, end_pos)
      pos = llvm_type.null
      pos = builder.insert_value pos, begin_pos, 0, "pos"
      pos = builder.insert_value pos, end_pos, 1, "pos"
      pos
    end
    
    def read(data, input, input_address)
      return nil if data[:begin].null?
      { __type__: :input_range, input: input, position: (data[:begin].address - input_address)...(data[:end].address - input_address) }
    end
  end
  
  class ScalarValueType < ValueType
    @@instances = {}

    def self.new(value)
      @@instances[value] ||= super
    end
    
    def initialize(value)
      @value = value
      super nil, nil
    end
    
    def read(data, input, input_address)
      @value
    end
  end
  
  class SingleValueType < ValueType
    def initialize(type)
      super type.llvm_type, type.ffi_type
      @type = type
    end
    
    def read(data, input, input_address)
      @type.read data, input, input_address
    end
  end
  
  class HashValueType < ValueType
    attr_reader :types
    
    def initialize(types)
      @types = types
      @types_with_data = @types.select { |key, value| value.llvm_type }
      
      llvm_type = LLVM::Struct(*@types_with_data.values.map(&:llvm_type))
      ffi_type = Class.new FFI::Struct
      if @types_with_data.empty?
        ffi_type.layout(:dummy, :char)
      else
        ffi_type.layout(*@types_with_data.map{ |name, type| [name, type.ffi_type] }.flatten)
      end
      super llvm_type, ffi_type
    end

    def create_llvm_value(builder, value, begin_pos = nil, end_pos = nil)
      data = llvm_type.null
      value.each do |name, entry|
        data = builder.insert_value data, entry, @types_with_data.keys.index(name), "hash_data_with_#{name}" if entry
      end
      data
    end
    
    def read_value(builder, data)
      value = {}
      @types_with_data.keys.each_with_index do |name, index|
         value[name] = builder.extract_value(data, index, name.to_s)
      end
      value
    end
    
    def read(data, input, input_address)
      values = {}
      @types.each do |name, type|
        values[name] = type.read((@types_with_data.has_key?(name) ? data[name] : nil), input, input_address)
      end
      values
    end
    
    def alloca(builder, name)
      @types.empty? ? LLVM::Pointer(llvm_type).null : super
    end

    def ==(other)
      other.class == self.class && other.types == @types
    end
  end
  
  class ChoiceValueType < ValueType
    attr_reader :reduced_types

    def initialize(types, name)
      @all_types = types
      @reduced_types = types.compact.uniq
      @name = name
      
      return super @reduced_types.first.llvm_type, @reduced_types.first.ffi_type if @reduced_types.size == 1

      ffi_layout = []
      @reduced_types.each_with_index do |choice, index|
        ffi_layout.push index.to_s.to_sym, choice.ffi_type
      end
      llvm_type = LLVM::Struct(LLVM::Int, *@reduced_types.map(&:llvm_type)) # TODO memory optimization with "union" structure and bitcasts
      ffi_type = Class.new FFI::Struct
      ffi_type.layout(:selection, :int, *ffi_layout)
      super llvm_type, ffi_type
    end
    
    def create_choice_value(builder, all_types_index, value)
      return value if @reduced_types.size == 1

      data = llvm_type.null
      if value
        reduced_types_index = @reduced_types.index @all_types[all_types_index]
        data = builder.insert_value data, LLVM::Int(reduced_types_index), 0, "choice_data_with_index"
        data = builder.insert_value data, value, reduced_types_index + 1, "choice_data_with_#{@name}"
      end
      data
    end
    
    def read(data, input, input_address)
      return @reduced_types.first.read data, input, input_address if @reduced_types.size == 1

      @reduced_types[data[:selection]].read data[data[:selection].to_s.to_sym], input, input_address
    end
    
    def ==(other)
      other.class == self.class && other.reduced_types == @reduced_types
    end
  end
  
  class PointerValueType < ValueType
    attr_reader :target
    
    def initialize(target)
      super LLVM::Pointer(LLVM::Int8), :pointer
      @target = target
    end
    
    def create_llvm_value(builder, value, begin_pos = nil, end_pos = nil)
      value = @target.return_type.create_llvm_value builder, value
      ptr = builder.malloc @target.return_type.llvm_type.size # TODO free
      casted_ptr = builder.bit_cast ptr, LLVM::Pointer(@target.return_type.llvm_type)
      builder.store value, casted_ptr
      ptr
    end
    
    def read(data, input, input_address)
      @target.return_type.load data, input, input_address
    end
    
    def ==(other)
      other.class == self.class && other.target == @target
    end
  end
  
  class ArrayValueType < ValueType
    attr_reader :entry_type, :return_type
    
    def initialize(entry_type)
      @entry_type = entry_type
      @pointer_type = PointerValueType.new self
      @return_type = HashValueType.new value: entry_type, previous: @pointer_type
      super @pointer_type.llvm_type, @pointer_type.ffi_type
    end
    
    def create_entry(builder, value, previous_entry)
      @pointer_type.create_llvm_value builder, { value: @entry_type.create_llvm_value(builder, value), previous: previous_entry }
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
      other.class == self.class && other.entry_type == @entry_type
    end
  end
    
  class CreatorType < ValueType
    attr_reader :creator_data, :data_type
    
    def initialize(data_type, creator_data = {})
      @data_type = data_type
      @creator_data = creator_data
      super @data_type.llvm_type, @data_type.ffi_type
    end
    
    def create_llvm_value(builder, value, begin_pos = nil, end_pos = nil)
      @data_type.create_llvm_value builder, value, begin_pos, end_pos
    end
    
    def read(data, input, input_address)
      result = @creator_data.clone
      result[:data] = @data_type.read(data, input, input_address)
      result
    end
    
    def ==(other)
      other.class == self.class && other.creator_data == @creator_data && other.data_type == @data_type
    end
  end
end
