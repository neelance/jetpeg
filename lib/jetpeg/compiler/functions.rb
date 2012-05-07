module JetPEG
  module Compiler
    class TrueFunction < ParsingExpression
      def initialize(data)
        super()
      end
      
      def create_return_type
        BooleanValueType.new parser.value_types 
      end
      
      def build(builder, start_input, modes, failed_block)
        Result.new start_input, LLVM::Int64.from_i(1)
      end
    end
    
    class FalseFunction < ParsingExpression
      def initialize(data)
        super()
      end
      
      def create_return_type
        BooleanValueType.new parser.value_types
      end
      
      def build(builder, start_input, modes, failed_block)
        Result.new start_input, LLVM::Int64.from_i(0)
      end
    end
    
    class MatchFunction < ParsingExpression
      def initialize(data)
        super()
        @string = data[:string]
        self.children = [@string]
      end

      def build(builder, start_input, modes, failed_block)
        expected_begin = builder.extract_value @string.value, 0
        expected_end = builder.extract_value @string.value, 1
        input = DynamicPhi.new builder, LLVM_STRING, "match_input", start_input
        expected = DynamicPhi.new builder, LLVM_STRING, "match_expected", expected_begin
        
        end_check_block = builder.create_block "match_end_check"
        char_check_block = builder.create_block "match_char_check"
        exit_block = builder.create_block "match_exit"
        builder.br end_check_block

        builder.position_at_end end_check_block
        input.build
        expected.build
        at_end = builder.icmp :eq, expected, expected_end, "at_end"
        builder.cond at_end, exit_block, char_check_block
        
        builder.position_at_end char_check_block
        failed = builder.icmp :ne, builder.load(input), builder.load(expected), "failed"
        builder.add_failure_reason failed, start_input, ParsingError.new([], ["$match failed"]) # TODO better failure message
        input << builder.gep(input, LLVM::Int(1), "new_input")
        expected << builder.gep(expected, LLVM::Int(1), "new_expected")
        builder.cond failed, failed_block, end_check_block
        
        builder.position_at_end exit_block
        Result.new input
      end
    end
    
    class ErrorFunction < ParsingExpression
      def initialize(data)
        super()
        @message = data[:message].string
      end
      
      def build(builder, start_input, modes, failed_block)
        builder.add_failure_reason LLVM::TRUE, start_input, ParsingError.new([], [@message])
        builder.br failed_block

        dummy_block = builder.create_block "error_dummy"
        builder.position_at_end dummy_block
        Result.new start_input
      end
    end
    
    class ModeFunction < ParsingExpression
      def initialize(data)
        super()
        @name = data[:name].string.to_sym
        if data[:expression]
          @expression = data[:expression]
          self.children = [@expression]
        end
      end
      
      def all_mode_names
        super + [@name]
      end
    end
    
    class EnterModeFunction < ModeFunction      
      def build(builder, start_input, modes, failed_block)
        new_modes = builder.insert_value modes, LLVM::TRUE, parser.mode_names.index(@name)
        @expression.build builder, start_input, new_modes, failed_block
      end
    end
    
    class LeaveModeFunction < ModeFunction
      def build(builder, start_input, modes, failed_block)
        new_modes = builder.insert_value modes, LLVM::FALSE, parser.mode_names.index(@name)
        @expression.build builder, start_input, new_modes, failed_block
      end
    end
    
    class InModeFunction < ModeFunction
      def build(builder, start_input, modes, failed_block)
        successful_block = builder.create_block "in_mode_successful"
        in_mode = builder.extract_value modes, parser.mode_names.index(@name), "in_mode_#{@name}"
        builder.cond in_mode, successful_block, failed_block
        builder.position_at_end successful_block
        Result.new start_input
      end
    end
  end
end