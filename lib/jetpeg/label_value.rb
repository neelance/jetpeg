module JetPEG
  class LabelValueType
    attr_reader :llvm_type, :ffi_type
    
    def initialize(llvm_type, ffi_type)
      @llvm_type = llvm_type
      @ffi_type = ffi_type
    end
    
    def phi_value(builder, index, value)
      value
    end
    
    def self.for_types(types)
      case
      when types.empty? then InputRangeLabelValueType::INSTANCE
      when delegate = types[DelegateLabelValueType::SYMBOL] then DelegateLabelValueType.new types
      else HashLabelValueType.new types
      end
    end
  end
  
  class InputRangeLabelValueType < LabelValueType
    INSTANCE = new LLVM::Struct(LLVM_STRING, LLVM_STRING), Class.new(FFI::Struct).tap{ |s| s.layout(:begin, :pointer, :end, :pointer) }
    
    def create_value(builder, labels, begin_pos, end_pos)
      pos = llvm_type.null
      pos = builder.insert_value pos, begin_pos, 0, "pos"
      pos = builder.insert_value pos, end_pos, 1, "pos"
      pos
    end
    
    def read(data, input, input_address)
      return nil if data[:begin].null?
      DataInputRange.new input, (data[:begin].address - input_address)...(data[:end].address - input_address)
    end
  end
  
  class HashLabelValueType < LabelValueType
    attr_reader :types
    
    def initialize(types)
      #raise ArgumentError if types.has_key?(DelegateLabelValueType::SYMBOL)
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
    
    def read_value(builder, data)
      labels = {}
      @types.each_with_index do |(name, type), index|
         labels[name] = builder.extract_value data, index, name.to_s
      end
      labels
    end
    
    def read(data, input, input_address)
      values = {}
      @types.each do |name, type|
        values[name] = type.read data[name], input, input_address
      end
      return values[DelegateLabelValueType::SYMBOL] if values.keys == [DelegateLabelValueType::SYMBOL] # TODO should not be here
      values
    end
    
    def ==(other)
      other.class == self.class && other.types == @types
    end
  end
  
  class NilLabelValueType < LabelValueType
    INSTANCE = new LLVM::Int8, :char
    
    def read(data, input, input_address)
      nil
    end
  end
  
  class ChoiceLabelValueType < LabelValueType
    attr_reader :choices
    
    def initialize(choices)
      @choices = choices.map { |choice| choice || NilLabelValueType::INSTANCE }
      ffi_layout = []
      @choices.each_with_index do |choice, index|
        ffi_layout.push index.to_s.to_sym, choice.ffi_type
      end
      llvm_type = LLVM::Struct(LLVM::Int, *@choices.map(&:llvm_type)) # TODO memory optimization with "union" structure and bitcasts
      ffi_type = Class.new FFI::Struct
      ffi_type.layout(:selection, :long, *ffi_layout)
      super llvm_type, ffi_type
    end
    
    def phi_value(builder, index, value)
      if value
        builder.insert_value(llvm_type.null, value, index + 1, "data_with_value")
      else
        llvm_type.null
      end
    end
    
    def read(data, input, input_address)
      @choices[data[:selection]].read data[data[:selection].to_s.to_sym], input, input_address
    end
    
    def ==(other)
      other.class == self.class && other.choices == @choices
    end
  end
  
  class PointerLabelValueType < LabelValueType
    attr_reader :target
    
    def initialize(target)
      super LLVM::Pointer(LLVM::Int8), :pointer
      @target = target
    end
    
    def hash_type
      raise ArgumentError if @target.label_types.empty?
      @hash_type ||= HashLabelValueType.new @target.label_types
    end
    
    def create_value(builder, labels, begin_pos = nil, end_pos = nil)
      value = hash_type.create_value builder, labels
      ptr = builder.call builder.parser.malloc, hash_type.llvm_type.size # TODO free
      casted_ptr = builder.bit_cast ptr, LLVM::Pointer(hash_type.llvm_type)
      builder.store value, casted_ptr
      ptr
    end
    
    def read(data, input, input_address)
      return nil if data.null?
      hash_data = hash_type.ffi_type.new data
      hash_type.read hash_data, input, input_address
    end
    
    def ==(other)
      other.class == self.class && other.target == @target
    end
  end
  
  class ArrayLabelValueType < LabelValueType
    attr_reader :entry_type, :label_types
    
    def initialize(entry_type)
      @entry_type = entry_type
      @pointer_type = PointerLabelValueType.new(self)
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
    
    def ==(other)
      other.class == self.class && other.entry_type == @entry_type
    end
  end
  
  class DelegateLabelValueType < LabelValueType
    SYMBOL = "@".to_sym
    attr_reader :type
    
    def initialize(types)
      raise CompilationError.new("Label @ mixed with other labels (#{types.keys.join(', ')}).") if types.size > 1
      @type = types[SYMBOL]
      super @type.llvm_type, @type.ffi_type
    end
    
    def types
      { SYMBOL => @type }
    end
    
    def create_value(builder, labels, begin_pos = nil, end_pos = nil)
      labels[SYMBOL]
    end
    
    def read_value(builder, data)
      { SYMBOL => data }
    end
    
    def read(data, input, input_address)
      @type.read data, input, input_address
    end
    
    def ==(other)
      other.class == self.class && other.type == @type
    end
  end
  
  class ObjectCreatorLabelType < LabelValueType
    attr_reader :class_name, :data_type
    
    def initialize(class_name, data_type)
      @class_name = class_name
      @data_type = data_type
      super @data_type.llvm_type, @data_type.ffi_type
    end
    
    def create_value(builder, labels, begin_pos = nil, end_pos = nil)
      @data_type.create_value builder, labels, begin_pos, end_pos
    end
    
    def read(data, input, input_address)
      DataObject.new @class_name, @data_type.read(data, input, input_address)
    end
    
    def ==(other)
      other.class == self.class && other.class_name == @class_name && other.data_type == @data_type
    end
  end
  
  class ValueCreatorLabelType < LabelValueType
    attr_reader :code, :data_type
    
    def initialize(code, data_type)
      @code = code
      @data_type = data_type
      super @data_type.llvm_type, @data_type.ffi_type
    end
    
    def create_value(builder, labels, begin_pos = nil, end_pos = nil)
      @data_type.create_value builder, labels, begin_pos, end_pos
    end
    
    def read(data, input, input_address)
      DataValue.new @code, @data_type.read(data, input, input_address)
    end
    
    def ==(other)
      other.class == self.class && other.code == @code && other.data_type == @data_type
    end
  end
end