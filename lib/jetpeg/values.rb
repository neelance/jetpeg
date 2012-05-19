module JetPEG
  class ValueType
    attr_reader :llvm_type, :child_types, :read_function, :free_function
    
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
    
    def create_functions(mod)
      @read_function = mod.functions.add("read_value", [llvm_type, *OUTPUT_FUNCTION_POINTERS], LLVM.Void())
      @read_function.linkage = :private
      
      @free_function = mod.functions.add("free_value", [llvm_type], LLVM.Void())
      @free_function.linkage = :private
    end
    
    def build_functions(builder)
      entry = @read_function.basic_blocks.append "entry"
      builder.position_at_end entry
      value, *output_functions_array = @read_function.params.to_a
      output_functions = Hash[*OUTPUT_INTERFACE_SIGNATURES.keys.zip(output_functions_array).flatten]
      build_read_function builder, value, output_functions
      builder.ret_void
      
      entry = @free_function.basic_blocks.append "entry"
      builder.position_at_end entry
      build_free_function builder, @free_function.params[0]
      builder.ret_void
    end
  end
  
  class InputRangeValueType < ValueType
    INSTANCE = new LLVM::Type.struct([LLVM_STRING, LLVM_STRING], true, self.name), []
    
    def all_labels
      [nil]
    end
    
    def build_read_function(builder, value, output_functions)
      builder.call output_functions[:new_input_range], builder.extract_value(value, 0), builder.extract_value(value, 1)
    end

    def build_free_function(builder, value)
      # empty
    end
  end
  
  class BooleanValueType < ValueType
    def initialize(value_types)
      super LLVM::Int64.type, value_types
    end
    
    def all_labels
      [nil]
    end
    
    def build_read_function(builder, value, output_functions)
      builder.call output_functions[:new_boolean], builder.trunc(value, LLVM::Int1)
    end
    
    def build_free_function(builder, value)
      # empty
    end
  end
  
  class StructValueType < ValueType
    attr_reader :layout_types
    
    def initialize(child_types, name, value_types)
      @child_layouts, @layout_types = process_types child_types
      
      llvm_type = LLVM::Type.struct(@layout_types.map(&:llvm_type), true, "#{self.class.name}_#{name}")
      super llvm_type, value_types
    end
    
    def insert_value(builder, struct, value, index)
      _, layout = @child_layouts[index]
      values = indices = nil
      if layout.is_a? Array
        values = builder.extract_values value, layout.size
        indices = layout
      else
        values = [value]
        indices = [layout]
      end
      builder.insert_values struct, values, indices
    end
    
    def build_read_entry(builder, type, layout, value, output_functions)
      element = nil
      if layout.is_a?(Array)
        element = type.llvm_type.null
        layout.each_with_index do |source_index, target_index|
          v = builder.extract_value value, source_index
          element = builder.insert_value element, v, target_index
        end
      else
        element = builder.extract_value value, layout
      end
      raise if type.read_function.nil?
      builder.call type.read_function, element, *output_functions.values
    end
    
    def build_free_entry(builder, type, layout, value)
      element = nil
      if layout.is_a?(Array)
        element = type.llvm_type.null
        layout.each_with_index do |source_index, target_index|
          v = builder.extract_value value, source_index
          element = builder.insert_value element, v, target_index
        end
      else
        element = builder.extract_value value, layout
      end
      builder.call type.free_function, element
    end
  end
  
  class SequenceValueType < StructValueType
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
    
    def build_read_function(builder, value, output_functions)
      @child_layouts.each_value do |type, layout|
        build_read_entry builder, type, layout, value, output_functions
      end
      builder.call output_functions[:merge_labels], LLVM::Int64.from_i(@child_layouts.size)
    end
    
    def build_free_function(builder, value)
      @child_layouts.each_value do |type, layout|
        build_free_entry builder, type, layout, value
      end
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
    
    def create_choice_value(builder, index, entry_result)
      struct = llvm_type.null
      struct = builder.insert_value struct, LLVM::Int64.from_i(index), 0
      struct = insert_value builder, struct, entry_result.return_value, index if entry_result.return_value
      struct
    end
    
    def all_labels
      @child_layouts.values.map(&:first).map(&:all_labels).reduce(&:|)
    end
    
    def build_read_function(builder, value, output_functions)
      end_block = builder.create_block "choice_read_end"
      nil_block = builder.create_block "choice_read_nil"
      child_blocks = @child_layouts.map { builder.create_block "choice_read_entry" }
      child_index = builder.extract_value value, 0
      builder.switch child_index, nil_block, @child_layouts.keys.map{ |i| LLVM::Int64.from_i(i) }.zip(child_blocks)
      
      @child_layouts.values.zip(child_blocks).each do |(type, layout), block|
        builder.position_at_end block
        build_read_entry builder, type, layout, value, output_functions
        builder.br end_block
      end
      
      builder.position_at_end nil_block
      builder.call output_functions[:new_nil]
      builder.br end_block
      
      builder.position_at_end end_block
    end
    
    def build_free_function(builder, value)
      end_block = builder.create_block "choice_free_end"
      child_blocks = @child_layouts.map { builder.create_block "choice_free_entry" }
      child_index = builder.extract_value value, 0
      builder.switch child_index, end_block, @child_layouts.size.times.map{ |i| [LLVM::Int64.from_i(i), child_blocks[i]] }
      
      @child_layouts.values.zip(child_blocks).each do |(type, layout), block|
        builder.position_at_end block
        build_free_entry builder, type, layout, value
        builder.br end_block
      end
      
      builder.position_at_end end_block
    end
  end
  
  class PointerValueType < ValueType
    def initialize(target, value_types)
      @target = target
      @target_struct = LLVM::Type.struct(nil, true, self.class.name)
      super LLVM::Pointer(@target_struct), value_types
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
    
    def all_labels
      [nil]
    end
    
    def build_read_function(builder, value, output_functions)
      null_block = builder.create_block "read_pointer_null"
      not_null_block = builder.create_block "read_pointer_not_null"
      end_block = builder.create_block "read_pointer_end"
      builder.cond builder.icmp(:eq, value, llvm_type.null), null_block, not_null_block
      
      builder.position_at_end null_block
      builder.call output_functions[:new_nil]
      builder.br end_block
      
      builder.position_at_end not_null_block
      builder.call @target.return_type.read_function, builder.load(builder.struct_gep(value, 0)), *output_functions.values
      builder.br end_block
      
      builder.position_at_end end_block
    end
    
    def build_free_function(builder, value)
      check_counter_block = builder.create_block "check_counter"
      follow_pointer_block = builder.create_block "follow_pointer"
      decrement_counter_block = builder.create_block "decrement_counter"
      continue_block = builder.create_block "continue"
      
      not_null = builder.icmp :ne, value, llvm_type.null, "not_null"
      builder.cond not_null, check_counter_block, continue_block
      
      builder.position_at_end check_counter_block
      additional_use_counter = builder.struct_gep value, 1, "additional_use_counter"
      old_counter_value = builder.load additional_use_counter
      no_additional_use = builder.icmp :eq, old_counter_value, LLVM::Int64.from_i(0), "no_additional_use"
      builder.cond no_additional_use, follow_pointer_block, decrement_counter_block
      
      builder.position_at_end follow_pointer_block
      target_value = builder.load builder.struct_gep value, 0, "target_value"
      builder.call @target.return_type.free_function, target_value
      builder.free value
      builder.br continue_block
      
      builder.position_at_end decrement_counter_block
      new_counter_value = builder.sub old_counter_value, LLVM::Int64.from_i(1)
      builder.store new_counter_value, additional_use_counter
      builder.br continue_block

      builder.position_at_end continue_block
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
      @pointer_type.realize
      super @pointer_type.llvm_type, value_types
    end
    
    def create_array_value(builder, entry_value, previous_entry)
      value = builder.create_struct @return_type.llvm_type
      value = @return_type.insert_value builder, value, entry_value, 0
      value = @return_type.insert_value builder, value, previous_entry, 1
      @pointer_type.store_value builder, value
    end
    
    def all_labels
      @inner_type ? [nil] : []
    end
    
    def build_read_function(builder, value, output_functions)
      builder.call @pointer_type.read_function, value, *output_functions.values
      builder.call output_functions[:make_array]
    end
    
    def build_free_function(builder, value)
      builder.call @pointer_type.free_function, value
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
    
    def build_free_function(builder, value)
      builder.call @inner_type.free_function, value
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
    
    def build_read_function(builder, value, output_functions)
      builder.call @inner_type.read_function, value, *output_functions.values
      builder.call output_functions[:make_label], builder.global_string_pointer(@name.to_s)
    end
    
    def to_s
      "#{self.class.name}(#{@name})"
    end
  end
    
  class CreatorValueType < WrappingValueType
    def initialize(inner_type, function, arguments, value_types)
      super inner_type, value_types
      @function = function
      @arguments = arguments
    end
    
    def all_labels
      @inner_type ? [nil] : []
    end
    
    def build_read_function(builder, value, output_functions)
      builder.call @inner_type.read_function, value, *output_functions.values
      mapped_arguments = @arguments.map { |arg|
        case arg
        when Integer then LLVM::Int64.from_i(arg) 
        when String then builder.global_string_pointer(arg)
        else raise
        end
      }
      builder.call output_functions[@function], *mapped_arguments
    end
  end
end
