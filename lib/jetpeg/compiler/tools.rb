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
      attr_reader :input, :return_type, :return_value # TODO may remove return_type
      
      def initialize(input, return_type = nil, return_value = nil)
        @input = input
        @return_type = return_type
        @return_value = return_value
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