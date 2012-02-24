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
        value = value.return_value if value.is_a? Result
        value = @type.create_choice_value @builder, @index, value if @type.is_a? ChoiceValueType
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
      
      def type
        @llvm_type
      end
    end
    
    class DynamicPhiHash
      def initialize(builder, struct_value_type)
        @builder = builder
        @struct_value_type = struct_value_type
        @phis = struct_value_type.types.map { |name, type| DynamicPhi.new(builder, type, name.to_s) }
        @struct_value = struct_value_type.create_value builder
      end
      
      def <<(result)
        @phis.each_with_index do |phi, index|
          phi << if result.return_type
            key = @struct_value_type.types.keys[index]
            index_in_result = result.return_type.types.keys.index key
            index_in_result && @builder.extract_value(result.return_value, index_in_result)
          else
            nil
          end
        end
      end
      
      def build
        phi_values = @phis.map(&:build) # all phis need to be at the beginning of the basic block
        phi_values.each_with_index do |phi_value, index|
          @struct_value = @builder.insert_value @struct_value, phi_value, index
        end 
        @struct_value
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
      def initialize(builder, input, return_type)
        super input, return_type
        @builder = builder
        @hash_mode = return_type.is_a? StructValueType
        @return_value = @hash_mode ? return_type.create_value(builder) : nil
      end
      
      def merge!(result)
        @input = result.input
        return self if not result.return_value
        
        if @hash_mode
          result.return_type.types.keys.each_with_index do |key, index|
            elem = @builder.extract_value result.return_value, index
            @return_value = @builder.insert_value @return_value, elem, @return_type.types.keys.index(key)
          end
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
        hash_mode = return_type.is_a? StructValueType
        @return_value_phi = if hash_mode
          DynamicPhiHash.new builder, return_type
        else
          return_type && DynamicPhi.new(builder, return_type, "return_value")
        end
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