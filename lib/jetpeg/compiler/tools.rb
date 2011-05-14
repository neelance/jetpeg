module JetPEG
  module Compiler
    class PhiGenerator
      def initialize(builder, type, name = "")
        @builder = builder
        @type = type
        @name = name
        @values = {}
      end
      
      def <<(value)
        @values[@builder.insert_block] = value || @type.null
      end
      
      def generate
        @builder.phi @type, @values, @name
      end
    end
    
    class LabelSlot
      attr_reader :slot_type
      
      def initialize(name, types)
        @name = name
        @types = types.compact.uniq
        @slot_type = @types.size > 1 ? ChoiceLabelValueType.new(@types) : @types.first
      end
      
      def slot_value(builder, value)
        if @types.size > 1
          data = @slot_type.llvm_type.null
          if value
            index = @types.index value.type
            data = builder.insert_value data, LLVM::Int(index), 0, "choice_data_with_index"
            data = builder.insert_value data, value, index + 1, "choice_data_with_#{@name}"
          end
          data
        else
          value
        end
      end
    end
        
    class Result
      attr_accessor :input, :labels
      
      def initialize(input = nil)
        @input = input
        @labels = {}
      end
      
      def merge!(result)
        @input = result.input
        @labels.merge! result.labels
        self
      end
    end
    
    class BranchingResult < Result
      def initialize(builder, slots)
        @builder = builder
        @slots = slots

        @input_phi = PhiGenerator.new builder, LLVM_STRING, "input"
        @label_phis = slots.each_with_object({}) { |(name, slot), h| h[name] = PhiGenerator.new builder, slot.slot_type.llvm_type, name.to_s }
      end
      
      def <<(result)
        @input_phi << result.input
        @label_phis.each { |name, phi|
          value = result.labels[name]
          phi << @slots[name].slot_value(@builder, value)
        }
      end
      
      def generate
        @input = @input_phi.generate
        @labels = @label_phis.each_with_object({}) { |(name, phi), h| h[name] = LabelValue.new phi.generate, @slots[name].slot_type }
        self
      end
    end
  end
end