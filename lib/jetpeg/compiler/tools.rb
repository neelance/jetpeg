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
        value = value.return_value if value.is_a? Result
        
        if @type.is_a? ChoiceValueType
          data = @type.llvm_type.null
          data = @builder.insert_value data, LLVM::Int(@index), 0, "choice_data_with_index"
          data = @builder.insert_value data, value, @index + 1, "choice_data_with_#{@type.name}" if value
          value = data
        end
        
        value ||= LLVM::Constant.null @llvm_type
        @values[@builder.insert_block] = value
        @phi.add_incoming @builder.insert_block => value if @phi
        @index += 1
      end
      
      def build
        raise if @phi
        @phi = @builder.phi @llvm_type, @values, @name
        @phi
      end
      
      def to_ptr
        @phi.to_ptr
      end
      
      def type
        @llvm_type
      end
    end
    
    class Result
      attr_reader :input, :return_type, :return_value
      
      def initialize(input, return_type = nil, return_value = nil)
        @input = input
        @return_type = return_type
        @return_value = return_value
      end
    end
    
    class MergingResult < Result
      def initialize(builder, input, return_type, hash_mode)
        super input, return_type
        @builder = builder
        @hash_mode = hash_mode
        @return_value = @hash_mode ? return_type.create_value(builder) : nil
        @insert_index = 0
      end
      
      def merge!(result)
        @input = result.input
        return self if not result.return_value
        
        if @hash_mode
          @return_value = @builder.insert_value @return_value, result.return_value, @insert_index
          @insert_index += 1
        elsif result.return_value
          raise "Internal error." if not @return_value.nil?
          @return_value = result.return_value
        end
        self
      end
    end
    
    class BranchingResult < Result
      def initialize(builder, return_type)
        super nil, return_type
        @builder = builder
        @input_phi = DynamicPhi.new builder, LLVM_STRING, "input"
        @return_value_phi = return_type && DynamicPhi.new(builder, return_type, "return_value")
        @local_values = []
      end
      
      def <<(result)
        @input_phi << result.input
        @return_value_phi << result if @return_value_phi
      end
      
      def build
        @input = @input_phi.build
        @return_value = @return_value_phi.build if @return_value_phi
        self
      end
    end
  end
    
  def self.write_typegraph(filename, llvm_type, all_types = false)
    File.open(filename, "w") do |out|
      out.puts "digraph {"
      
      queue = [[llvm_type.to_ptr.address, llvm_type]]
      seen = [llvm_type.to_ptr.address]
      
      until queue.empty?
        id, type = queue.shift
        
        label = type.kind.to_s
        label << " \\\"#{type.name}\\\"" if type.kind == :struct
        out.puts "#{id} [label=\"#{label}\"];"
        
        if type.kind == :struct
          type.element_types.each do |element_type|
            attributes = ""
            if element_type.kind == :pointer
              attributes = "style=dashed,arrowhead=empty"
              element_type = element_type.element_type
            end
            if all_types or element_type.kind == :struct or element_type.kind == :pointer
              element_id = element_type.to_ptr.address
              out.puts "#{id} -> #{element_id} [#{attributes}];"
              if not seen.include? element_id
                queue << [element_id, element_type]
                seen << element_id
              end
            end
          end
        end
      end
      
      out.puts "}"
    end
  end
end