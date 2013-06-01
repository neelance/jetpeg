module JetPEG
  module Compiler
    class Function < ParsingExpression
      def build(builder, start_input, modes, failed_block)
        case @data[:name]
        when "true"
          builder.call builder.output_functions[:push_boolean], LLVM::TRUE
          return start_input, true

        when "false"
          builder.call builder.output_functions[:push_boolean], LLVM::FALSE
          return start_input, true

        when "match"
          successful_block = builder.function.basic_blocks.append "match_successful"
          trace_failure_block = builder.function.basic_blocks.append "match_trace_failure"

          @data[:arguments][0].build builder, start_input, modes, failed_block
          end_input = builder.call builder.output_functions[:match], start_input
          successful = builder.icmp :ne, end_input, LLVM_STRING.null, "match_successful"
          builder.cond successful, successful_block, trace_failure_block

          builder.position_at_end trace_failure_block
          builder.call builder.output_functions[:trace_failure], start_input, builder.global_string_pointer("$match failed"), LLVM::FALSE if builder.traced # TODO better failure message
          builder.br failed_block

          builder.position_at_end successful_block
          return end_input, false

        when "error"
          builder.call builder.output_functions[:trace_failure], start_input, builder.global_string_pointer(@data[:arguments][0].data[:string]), LLVM::FALSE if builder.traced # TODO better failure message
          builder.br failed_block

          dummy_block = builder.function.basic_blocks.append "error_dummy"
          builder.position_at_end dummy_block
          return start_input, false

        when "enter_mode"
          new_modes = builder.insert_value modes, LLVM::TRUE, parser.mode_indices[@data[:arguments][0].data[:string]]
          return @data[:arguments][1].build builder, start_input, new_modes, failed_block

        when "leave_mode"
          new_modes = builder.insert_value modes, LLVM::FALSE, parser.mode_indices[@data[:arguments][0].data[:string]]
          return @data[:arguments][1].build builder, start_input, new_modes, failed_block

        when "in_mode"
          successful_block = builder.function.basic_blocks.append "in_mode_successful"
          in_mode = builder.extract_value modes, parser.mode_indices[@data[:arguments][0].data[:string]], "in_mode_#{@data[:arguments][0].data[:string]}"
          builder.cond in_mode, successful_block, failed_block
          builder.position_at_end successful_block
          return start_input, false
        end
      end
    end

    class StringValue < ParsingExpression
      block :_entry do
        push_string @_builder.global_string_pointer(@_data[:string])
        br :_successful
      end
    end
  end
end