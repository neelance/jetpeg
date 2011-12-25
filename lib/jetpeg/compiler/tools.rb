module JetPEG
  module Compiler
    class DynamicPhi
      def initialize(builder, type, name = "", first_value = nil)
        @builder = builder
        @type = type
        @name = name
        @values = {}
        @phi = nil
        self << first_value if first_value
      end
      
      def <<(value)
        value ||= @type.null
        @values[@builder.insert_block] = value
        @phi.add_incoming @builder.insert_block => value if @phi
      end
      
      def build
        raise if @phi
        @phi = @builder.phi @type, @values, @name
        @phi
      end
      
      def to_ptr
        @phi.to_ptr
      end
    end
    
    class LabelSlot
      attr_reader :slot_type
      
      def initialize(name, types)
        @name = name
        @all_types = types
        @reduced_types = types.compact.uniq
        @slot_type = @reduced_types.size > 1 ? ChoiceValueType.new(@reduced_types) : @reduced_types.first
      end
      
      def slot_value(builder, value, child_index)
        if @reduced_types.size > 1
          @slot_type.create_choice_value builder, @all_types[child_index], value, @name
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
      def initialize(builder, return_type)
        @builder = builder
        @input_phi = DynamicPhi.new builder, LLVM_STRING, "input"
        types = case return_type
        when nil
          {}
        when Hash
          return_type
        else
          return_type.types
        end
        @label_phis = types.map_hash { |name, type| DynamicPhi.new builder, type.llvm_type, name.to_s }
      end
      
      def <<(result)
        @input_phi << result.input
        @label_phis.each do |name, phi|
          phi << result.labels[name]
        end
      end
      
      def build
        @input = @input_phi.build
        @labels = @label_phis.map_hash { |name, phi| phi.build }
        self
      end
    end
  end
end