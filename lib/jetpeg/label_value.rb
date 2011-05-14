module JetPEG
  AT_SYMBOL = "@".to_sym
  
  class LabelValue
    attr_reader :value, :type
    
    def initialize(value, type)
      @value = value
      @type = type
    end
    
    def to_ptr
      @value.to_ptr
    end
  end
  
  class LabelValueType
    attr_reader :llvm_type, :ffi_type
    
    def initialize(llvm_type, ffi_type)
      @llvm_type = llvm_type
      @ffi_type = ffi_type
    end
    
    def create_value(builder, labels, begin_pos = nil, end_pos = nil)
      LabelValue.new create_llvm_value(builder, labels, begin_pos, end_pos), self
    end
    
    def load(pointer, input, input_address)
      return nil if pointer.null?
      data = if ffi_type == :pointer
        pointer.get_pointer 0
      else
        ffi_type.new pointer
      end
      read data, input, input_address
    end
    
    def empty?
      false
    end
  end
  
  class InputRangeLabelValueType < LabelValueType
    INSTANCE = new LLVM::Struct(LLVM_STRING, LLVM_STRING), Class.new(FFI::Struct).tap{ |s| s.layout(:begin, :pointer, :end, :pointer) }
    
    def create_llvm_value(builder, labels, begin_pos, end_pos)
      pos = llvm_type.null
      pos = builder.insert_value pos, begin_pos, 0, "pos"
      pos = builder.insert_value pos, end_pos, 1, "pos"
      pos
    end
    
    def read(data, input, input_address)
      return nil if data[:begin].null?
      { :$type => :input_range, :input => input, :position => (data[:begin].address - input_address)...(data[:end].address - input_address) }
    end
  end
  
  class HashLabelValueType < LabelValueType
    attr_reader :types
    
    def initialize(types)
      raise CompilationError.new("Label @ mixed with other labels (#{types.keys.join(', ')}).") if types.has_key?(AT_SYMBOL) and types.size > 1
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

    def create_llvm_value(builder, labels, begin_pos = nil, end_pos = nil)
      data = llvm_type.null
      labels.each_with_index do |(name, value), index|
        data = builder.insert_value data, value, index, "hash_data_with_#{name}"
      end
      data
    end
    
    def read_value(builder, data)
      labels = {}
      @types.each_with_index do |(name, type), index|
         labels[name] = LabelValue.new builder.extract_value(data, index, name.to_s), type
      end
      labels
    end
    
    def read(data, input, input_address)
      values = {}
      @types.each do |name, type|
        values[name] = type.read data[name], input, input_address
      end
      values[AT_SYMBOL] || values
    end
    
    def ==(other)
      other.class == self.class && other.types == @types
    end
    
    def empty?
      @types.empty?
    end
  end
  
  class ChoiceLabelValueType < LabelValueType
    attr_reader :choices
    
    def initialize(choices)
      @choices = choices
      ffi_layout = []
      @choices.each_with_index do |choice, index|
        ffi_layout.push index.to_s.to_sym, choice.ffi_type
      end
      llvm_type = LLVM::Struct(LLVM::Int, *@choices.map(&:llvm_type)) # TODO memory optimization with "union" structure and bitcasts
      ffi_type = Class.new FFI::Struct
      ffi_type.layout(:selection, :long, *ffi_layout)
      super llvm_type, ffi_type
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
    
    def target_type
      @target_type ||= HashLabelValueType.new @target.label_types
    end
    
    def create_llvm_value(builder, labels, begin_pos = nil, end_pos = nil)
      value = target_type.create_llvm_value builder, labels
      ptr = builder.malloc target_type.llvm_type.size # TODO free
      casted_ptr = builder.bit_cast ptr, LLVM::Pointer(target_type.llvm_type)
      builder.store value, casted_ptr
      ptr
    end
    
    def read(data, input, input_address)
      target_type.load data, input, input_address
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
      @pointer_type.create_llvm_value builder, { :value => @entry_type.create_llvm_value(builder, labels), :previous => previous_entry }
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
    
  class CreatorLabelType < LabelValueType
    attr_reader :creator_data, :data_type
    
    def initialize(data_type, creator_data = {})
      @data_type = data_type
      @creator_data = creator_data
      super @data_type.llvm_type, @data_type.ffi_type
    end
    
    def create_llvm_value(builder, labels, begin_pos = nil, end_pos = nil)
      @data_type.create_llvm_value builder, labels, begin_pos, end_pos
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