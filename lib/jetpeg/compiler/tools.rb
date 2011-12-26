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
    
    class DynamicPhiHash
      def initialize(builder, types)
        @builder = builder
        @phis = types.map_hash { |name, type| [DynamicPhi.new(builder, type.llvm_type, name.to_s), type] }
        @index = 0
      end
      
      def <<(value)
        @phis.each do |name, (phi, type)|
          phi_value = value && value[name]
          phi_value = type.create_choice_value @builder, @index, phi_value if type.is_a?(ChoiceValueType)
          phi << phi_value
        end
        @index += 1
      end
      
      def build
        @phis.map_hash { |name, (phi, _)| phi.build }
      end
    end
    
    class Result
      attr_accessor :input, :value
      
      def initialize(input, return_type = nil)
        @input = input
        @hash_mode = return_type.is_a?(HashValueType) || return_type.is_a?(ChoiceValueType)
        @value = @hash_mode ? {} : nil
      end
      
      def merge!(result)
        @input = result.input
        if @hash_mode
          @value.merge! result.value if result.value
        elsif result.value
          raise "Internal error." if not @value.nil?
          @value = result.value
        end
        self
      end
    end
    
    class BranchingResult < Result
      def initialize(builder, return_type)
        @builder = builder
        @input_phi = DynamicPhi.new builder, LLVM_STRING, "input"
        hash_mode = return_type.is_a?(HashValueType) || return_type.is_a?(ChoiceValueType)
        @value_phi = if hash_mode
          DynamicPhiHash.new builder, return_type.types
        else
          return_type && DynamicPhi.new(builder, return_type.llvm_type, "return_value")
        end
      end
      
      def <<(result)
        @input_phi << result.input
        @value_phi << result.value if @value_phi
      end
      
      def build
        @input = @input_phi.build
        @value = @value_phi.build if @value_phi
        self
      end
    end
  end
end