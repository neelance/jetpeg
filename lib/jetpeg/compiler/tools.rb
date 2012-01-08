module JetPEG
  module Compiler
    class DynamicPhi
      def initialize(builder, type, name = "", first_value = nil)
        @builder = builder
        @type = type
        @llvm_type = type.is_a?(ValueType) ? type.llvm_type : type
        @name = name
        @values = {}
        @phi = nil
        @index = 0
        self << first_value if first_value
      end
      
      def <<(value)
        return if @type.nil?
        value = @type.create_choice_value @builder, @index, value if @type.is_a?(ChoiceValueType)
        value ||= LLVM::Constant.null @llvm_type
        @values[@builder.insert_block] = value
        @phi.add_incoming @builder.insert_block => value if @phi
        @index += 1
      end
      
      def build
        return if @type.nil?
        raise if @phi
        @phi = @builder.phi @llvm_type, @values, @name
        @phi
      end
      
      def to_ptr
        @phi.to_ptr
      end
    end
    
    class DynamicPhiHash
      def initialize(builder, types)
        @phis = types.map_hash { |name, type| DynamicPhi.new(builder, type, name.to_s) }
      end
      
      def <<(value)
        @phis.each { |name, phi| phi << (value && value[name]) }
      end
      
      def build
        @phis.map_hash { |name, phi| phi.build }
      end
    end
    
    class Result
      attr_accessor :input, :return_value
      
      def initialize(input, return_type = nil)
        @input = input
        @hash_mode = return_type.is_a? HashValueType
        @return_value = @hash_mode ? {} : nil
        @local_values = []
      end
      
      def merge!(result)
        @input = result.input
        if @hash_mode
          @return_value.merge! result.return_value if result.return_value
        elsif result.return_value
          raise "Internal error." if not @return_value.nil?
          @return_value = result.return_value
        end
        self
      end
    end
    
    class BranchingResult
      attr_accessor :input, :return_value

      def initialize(builder, return_type)
        @builder = builder
        @input_phi = DynamicPhi.new builder, LLVM_STRING, "input"
        hash_mode = return_type.is_a? HashValueType
        @return_value_phi = if hash_mode
          DynamicPhiHash.new builder, return_type.types
        else
          return_type && DynamicPhi.new(builder, return_type, "return_value")
        end
        @local_values = []
      end
      
      def <<(result)
        @input_phi << result.input
        @return_value_phi << result.return_value if @return_value_phi
      end
      
      def build
        @input = @input_phi.build
        @return_value = @return_value_phi.build if @return_value_phi
        self
      end
    end
  end
end