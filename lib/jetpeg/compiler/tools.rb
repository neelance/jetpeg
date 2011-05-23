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
          @slot_type.create_choice_value builder, value, @name
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
      def initialize(builder, types)
        @builder = builder
        @types = types

        @input_phi = PhiGenerator.new builder, LLVM_STRING, "input"
        @label_phis = types.map_hash { |name, type| PhiGenerator.new builder, type.llvm_type, name.to_s }
      end
      
      def <<(result)
        @input_phi << result.input
        @label_phis.each do |name, phi|
          phi << result.labels[name]
        end
      end
      
      def generate
        @input = @input_phi.generate
        @labels = @label_phis.map_hash { |name, phi| LabelValue.new phi.generate, @types[name] }
        self
      end
    end
  end
end