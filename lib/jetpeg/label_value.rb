module JetPEG
  class LabelValueType
    attr_reader :llvm_type, :ffi_type
    
    def initialize(llvm_type, ffi_type)
      @llvm_type = llvm_type
      @ffi_type = ffi_type
    end
  end
  
  class TerminalLabelValueType < LabelValueType
    INSTANCE = new LLVM::Struct(LLVM_STRING, LLVM_STRING), Class.new(FFI::Struct).tap{ |s| s.layout(:begin, :pointer, :end, :pointer) }

    def create_value(builder, labels, begin_pos, end_pos)
      pos = INSTANCE.llvm_type.null
      pos = builder.insert_value pos, begin_pos, 0, "pos"
      pos = builder.insert_value pos, end_pos, 1, "pos"
      pos
    end
    
    def read(data, input, input_address)
      if data[:begin].null?
        nil
      else
        InputRange.new input, (data[:begin].address - input_address)...(data[:end].address - input_address)
      end
    end
  end
  
  class HashLabelValueType < LabelValueType
    attr_reader :types
    
    def initialize(types)
      @types = types
      llvm_type = LLVM::Struct(*types.values.map(&:llvm_type))
      ffi_type = Class.new FFI::Struct
      ffi_type.layout(*types.map{ |name, type| [name, type.ffi_type] }.flatten)
      super llvm_type, ffi_type
    end

    def create_value(builder, labels, begin_pos = nil, end_pos = nil)
      data = llvm_type.null
      labels.each_with_index do |(name, value), index|
        raise if data.type == value.type
        data = builder.insert_value data, value, index, "data_with_#{name}"
      end
      data
    end
    
    def read(data, input, input_address)
      values = {}
      @types.each do |name, type|
        values[name] = type.read data[name], input, input_address
      end
      values
    end
    
    def ==(other)
      @types == other.types
    end
    
    def empty?
      @types.empty?
    end

    EMPTY_TYPE = new({})
  end
  
  class PointerLabelValueType < LabelValueType
    def initialize(malloc, expression)
      super LLVM::Pointer(LLVM::Int8), :pointer
      @malloc = malloc
      @expression = expression
    end
    
    def hash_type
      @hash_type ||= HashLabelValueType.new @expression.label_types
    end
    
    def create_value(builder, labels, begin_pos = nil, end_pos = nil)
      value = hash_type.create_value builder, labels
      ptr = builder.call @malloc, hash_type.llvm_type.size
      casted_ptr = builder.bit_cast ptr, LLVM::Pointer(hash_type.llvm_type)
      builder.store value, casted_ptr
      ptr
    end
    
    def read(data, input, input_address)
      return nil if data.null?
      hash_data = hash_type.ffi_type.new data
      hash_type.read hash_data, input, input_address
    end
  end
end