module JetPEG
  module Compiler
    class TrueFunction < ParsingExpression
      def build(builder, start_input, modes, failed_block)
        builder.call builder.output_functions[:push_boolean], LLVM::TRUE
        return start_input, true
      end
    end
    
    class FalseFunction < ParsingExpression
      def build(builder, start_input, modes, failed_block)
        builder.call builder.output_functions[:push_boolean], LLVM::FALSE
        return start_input, true
      end
    end
    
    class MatchFunction < ParsingExpression
      def build(builder, start_input, modes, failed_block)
        exit_block = builder.create_block "match_exit"

        @children.first.build builder, start_input, modes, failed_block
        end_input = builder.call builder.output_functions[:match], start_input
        successful = builder.icmp :ne, end_input, LLVM_STRING.null, "match_successful"
        builder.cond successful, exit_block, builder.add_failure_reason(failed_block, start_input, "$match failed", false) # TODO better failure message
        
        builder.position_at_end exit_block
        return end_input, false
      end
    end
    
    class ErrorFunction < ParsingExpression
      def build(builder, start_input, modes, failed_block)
        builder.br builder.add_failure_reason(failed_block, start_input, @data[:message], false)

        dummy_block = builder.create_block "error_dummy"
        builder.position_at_end dummy_block
        return start_input, false
      end
    end
    
    class ModeFunction < ParsingExpression
      def all_mode_names
        super + [@data[:name]]
      end
    end
    
    class EnterModeFunction < ModeFunction      
      def build(builder, start_input, modes, failed_block)
        new_modes = builder.insert_value modes, LLVM::TRUE, parser.mode_names.index(@data[:name])
        return @children.first.build builder, start_input, new_modes, failed_block
      end
    end
    
    class LeaveModeFunction < ModeFunction
      def build(builder, start_input, modes, failed_block)
        new_modes = builder.insert_value modes, LLVM::FALSE, parser.mode_names.index(@data[:name])
        return @children.first.build builder, start_input, new_modes, failed_block
      end
    end
    
    class InModeFunction < ModeFunction
      def build(builder, start_input, modes, failed_block)
        successful_block = builder.create_block "in_mode_successful"
        in_mode = builder.extract_value modes, parser.mode_names.index(@data[:name]), "in_mode_#{@data[:name]}"
        builder.cond in_mode, successful_block, failed_block
        builder.position_at_end successful_block
        return start_input, false
      end
    end
  end
end