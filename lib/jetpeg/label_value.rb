module JetPEG
  class LabelValueType
    attr_reader :llvm_type, :ffi_type
    
    def initialize(llvm_type, ffi_type)
      @llvm_type = llvm_type
      @ffi_type = ffi_type
    end
    
    def self.for_types(types)
      case
      when types.empty? then InputRangeLabelValueType
      when delegate = types[DelegateLabelValueType::SYMBOL] then DelegateLabelValueType 
      else HashLabelValueType
      end.new types
    end
  end
  
  class InputRangeLabelValueType < LabelValueType
    def initialize(types)
      super LLVM::Struct(LLVM_STRING, LLVM_STRING), Class.new(FFI::Struct).tap{ |s| s.layout(:begin, :pointer, :end, :pointer) }
    end

    def create_value(builder, labels, begin_pos, end_pos)
      pos = llvm_type.null
      pos = builder.insert_value pos, begin_pos, 0, "pos"
      pos = builder.insert_value pos, end_pos, 1, "pos"
      pos
    end
    
    def ==(other)
      other.is_a? InputRangeLabelValueType
    end
    
    def read(data, input, input_address)
      return nil if data[:begin].null?
      InputRange.new input, (data[:begin].address - input_address)...(data[:end].address - input_address)
    end
  end
  
  class HashLabelValueType < LabelValueType
    attr_reader :types
    
    def initialize(types)
      @types = types
      llvm_type = LLVM::Struct(*types.values.map(&:llvm_type))
      ffi_type = Class.new FFI::Struct
      if types.empty?
        ffi_type.layout(:dummy, :char)
      else
        ffi_type.layout(*types.map{ |name, type| [name, type.ffi_type] }.flatten)
      end
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

    EMPTY_TYPE = new({})
  end
  
  class PointerLabelValueType < LabelValueType
    def initialize(malloc, target)
      super LLVM::Pointer(LLVM::Int8), :pointer
      @malloc = malloc
      @target = target
    end
    
    def hash_type
      @hash_type ||= HashLabelValueType.new @target.label_types
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
  
  class ArrayLabelValueType < LabelValueType
    attr_reader :label_types
    
    def initialize(malloc, entry_type)
      @entry_type = entry_type
      @pointer_type = PointerLabelValueType.new(malloc, self)
      @label_types = { :value => entry_type, :previous => @pointer_type }
      super @pointer_type.llvm_type, @pointer_type.ffi_type
    end
    
    def create_entry(builder, labels, previous_entry)
      @pointer_type.create_value builder, { :value => @entry_type.create_value(builder, labels), :previous => previous_entry }
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
  end
  
  class DelegateLabelValueType < LabelValueType
    SYMBOL = "@".to_sym
    
    def initialize(types)
      raise SyntaxError, "Label @ mixed with other labels." if types.size > 1
      @type = types[SYMBOL]
      super @type.llvm_type, @type.ffi_type
    end
    
    def create_value(builder, labels, begin_pos = nil, end_pos = nil)
      labels[SYMBOL]
    end
    
    def read(data, input, input_address)
      @type.read data, input, input_address
    end
  end
end