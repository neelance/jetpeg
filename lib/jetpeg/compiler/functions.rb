module JetPEG
  module Compiler
    class TrueFunction < ParsingExpression
      def initialize(data)
        super()
      end
      
      def create_return_type
        parser.scalar_value_type
      end
      
      def build(builder, start_input, failed_block)
        Result.new start_input, return_type, parser.scalar_value_for(true)
      end
    end
    
    class FalseFunction < ParsingExpression
      def initialize(data)
        super()
      end
      
      def create_return_type
        parser.scalar_value_type
      end
      
      def build(builder, start_input, failed_block)
        Result.new start_input, return_type, parser.scalar_value_for(false)
      end
    end
    
    class ErrorFunction < ParsingExpression
      def initialize(data)
        super()
        @message = data[:message].string
      end
      
      def build(builder, start_input, failed_block)
        builder.add_failure_reason LLVM::TRUE, start_input, ParsingError.new([], [@message])
        builder.br failed_block

        dummy_block = builder.create_block "error_dummy"
        builder.position_at_end dummy_block
        Result.new start_input
      end
    end
  end
end