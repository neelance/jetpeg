module JetPEG
  module Compiler
    class Function < ParsingExpression
      def all_mode_names
        case @data[:name]
        when "enter_mode", "leave_mode", "in_mode"
          super + [data[:arguments][0].data[:string]]
        else
          super
        end
      end

      def build(builder, start_input, modes, failed_block)
        case @data[:name]
        when "true"
          builder.call builder.output_functions[:push_boolean], LLVM::TRUE
          return start_input, true

        when "false"
          builder.call builder.output_functions[:push_boolean], LLVM::FALSE
          return start_input, true

        when "match"
          exit_block = builder.create_block "match_exit"

          @data[:arguments][0].build builder, start_input, modes, failed_block
          end_input = builder.call builder.output_functions[:match], start_input
          successful = builder.icmp :ne, end_input, LLVM_STRING.null, "match_successful"
          builder.cond successful, exit_block, builder.trace_failure_reason(failed_block, start_input, "$match failed", false) # TODO better failure message
          
          builder.position_at_end exit_block
          return end_input, false

        when "error"
          builder.br builder.trace_failure_reason(failed_block, start_input, @data[:arguments][0].data[:string], false)

          dummy_block = builder.create_block "error_dummy"
          builder.position_at_end dummy_block
          return start_input, false

        when "enter_mode"
          new_modes = builder.insert_value modes, LLVM::TRUE, parser.mode_names.index(@data[:arguments][0].data[:string])
          return @data[:arguments][1].build builder, start_input, new_modes, failed_block

        when "leave_mode"
          new_modes = builder.insert_value modes, LLVM::FALSE, parser.mode_names.index(@data[:arguments][0].data[:string])
          return @data[:arguments][1].build builder, start_input, new_modes, failed_block

        when "in_mode"
          successful_block = builder.create_block "in_mode_successful"
          in_mode = builder.extract_value modes, parser.mode_names.index(@data[:arguments][0].data[:string]), "in_mode_#{@data[:arguments][0].data[:string]}"
          builder.cond in_mode, successful_block, failed_block
          builder.position_at_end successful_block
          return start_input, false
        end
      end
    end

    class StringValue < ParsingExpression
      def build(builder, start_input, modes, failed_block)
        builder.call builder.output_functions[:push_string], builder.global_string_pointer(@data[:string])
        return start_input, false
      end
    end
  end
end