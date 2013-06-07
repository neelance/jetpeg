module JetPEG
  module Compiler
    class TrueFunction < ParsingExpression
      block :_entry do
        push_boolean LLVM::TRUE
        @_has_return_value = true
        br :_successful
      end
    end

    class FalseFunction < ParsingExpression
      block :_entry do
        push_boolean LLVM::FALSE
        @_has_return_value = true
        br :_successful
      end
    end

    class MatchFunction < ParsingExpression
      block :_entry do
        build :value, @_start_input, :_failed
        @_end_input = match @_start_input
        @successful = icmp :ne, @_end_input, LLVM_STRING.null
        cond @successful, :_successful, :_failed
      end

      block :_failed do
        trace_failure @_start_input, string("$match failed"), LLVM::FALSE if @_traced # TODO better failure message
      end
    end

    class ErrorFunction < ParsingExpression
      block :_entry do
        trace_failure @_start_input, string(:msg), LLVM::FALSE if @_traced # TODO better failure message
        br :_failed
      end
    end

    class EnterModeFunction < ParsingExpression
      block :_entry do
        @_modes = insert_value @_modes, LLVM::TRUE, @_parser.mode_indices[@_data[:name]]
        @_end_input, @_has_return_value = build :child, @_start_input, :_failed
        br :_successful
      end
    end

    class LeaveModeFunction < ParsingExpression
      block :_entry do
        @_modes = insert_value @_modes, LLVM::FALSE, @_parser.mode_indices[@_data[:name]]
        @_end_input, @_has_return_value = build :child, @_start_input, :_failed
        br :_successful
      end
    end

    class InModeFunction < ParsingExpression
      block :_entry do
        @in_mode = extract_value @_modes, @_parser.mode_indices[@_data[:name]]
        cond @in_mode, :_successful, :_failed
      end
    end

    class StringValue < ParsingExpression
      block :_entry do
        push_string string(:string)
        br :_successful
      end
    end
  end
end