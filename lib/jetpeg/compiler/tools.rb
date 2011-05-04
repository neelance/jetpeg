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
      def initialize(builder, label_types)
        @input_phi = PhiGenerator.new builder, LLVM_STRING, "input"
        @label_phis = label_types.each_with_object({}) { |(name, type), h| h[name] = PhiGenerator.new builder, type.llvm_type, name.to_s }
      end
      
      def <<(result)
        @input_phi << result.input
        @label_phis.each { |name, phi| phi << result.labels[name] }
      end
      
      def generate
        @input = @input_phi.generate
        @labels = @label_phis.each_with_object({}) { |(name, phi), h| h[name] = phi.generate }
        self
      end
    end
    
    class RecursionGuard
      def initialize(recursion_value, &value_block)
        @recursion_value = recursion_value
        @value_block = value_block
        @value = nil
        @recursion = false
      end
      
      def value
        if @value.nil?
          if @recursion
            @value = @recursion_value
          else
            @recursion = true
            value = @value_block.call
            if @value.nil? # no recursion
              @value = value
            end
          end
        end
        @value
      end
    end
  end
end