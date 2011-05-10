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
      def initialize(builder, label_types, is_choice = {})
        @builder = builder
        @label_types = label_types
        @is_choice = is_choice

        @input_phi = PhiGenerator.new builder, LLVM_STRING, "input"
        @label_phis = label_types.each_with_object({}) { |(name, type), h| h[name] = PhiGenerator.new builder, type.llvm_type, name.to_s }
        if @is_choice.values.any?
          @selection_phi = PhiGenerator.new builder, LLVM::Int, "selection"
        else
          @selection_phi = nil
        end

        @index = 0
      end
      
      def <<(result)
        @input_phi << result.input
        @selection_phi << LLVM::Int(@index) if @selection_phi
        @label_phis.each { |name, phi|
          value = result.labels[name]
          phi << if @is_choice[name]
            choice_llvm_type = @label_types[name].llvm_type
            if value
              @builder.insert_value choice_llvm_type.null, value, @index + 1, "choice_data_with_#{name}"
            else
              choice_llvm_type.null
            end
          else
            value
          end
        }
        @index += 1
      end
      
      def generate
        @input = @input_phi.generate
        @labels = @label_phis.each_with_object({}) { |(name, phi), h| h[name] = phi.generate }
        if @selection_phi
          selection = @selection_phi.generate
          @labels.each { |name, data|
            @labels[name] = @builder.insert_value data, selection, 0, "data_with_selection" if @is_choice[name]
          }
        end
        self
      end
    end
  end
end