module JetPEG
  module Compiler
    class StringTerminal < ParsingExpression
      leftmost_leaves :self

      def build(builder, start_input, modes, failed_block)
        string = @data[:content].gsub(/\\./) { |str| Compiler.translate_escaped_character str[1] }
        end_input = string.chars.inject(start_input) do |input, char|
          successful = builder.icmp :eq, builder.load(input), LLVM::Int8.from_i(char.ord), "failed"
          next_char_block = builder.create_block "string_terminal_next_char"
          builder.cond successful, next_char_block, builder.trace_failure_reason(failed_block, start_input, string)
          
          builder.position_at_end next_char_block
          builder.gep input, LLVM::Int(1), "new_input"
        end
        return end_input, false
      end
    end
    
    class CharacterClassTerminal < ParsingExpression
      leftmost_leaves :self

      def build(builder, start_input, modes, failed_block)
        successful_block = builder.create_block "character_class_successful" unless @data[:inverted]
        
        @data[:selections].each do |selection|
          next_selection_block = builder.create_block "character_class_next_selection"
          selection.build builder, start_input, (@data[:inverted] ? failed_block : successful_block), next_selection_block
          builder.position_at_end next_selection_block
        end
        
        unless @data[:inverted]
          builder.br failed_block
          builder.position_at_end successful_block
        end
        
        end_input = builder.gep start_input, LLVM::Int(1), "new_input"
        return end_input, false
      end
    end
    
    class CharacterClassSingleCharacter < ParsingExpression
      def build(builder, start_input, successful_block, failed_block)
        input_char = builder.load start_input, "char"
        successful = builder.icmp :eq, input_char, LLVM::Int8.from_i(@data[:character].ord), "matching"
        builder.cond successful, successful_block, builder.trace_failure_reason(failed_block, start_input, @data[:character])
      end
    end
    
    class CharacterClassEscapedCharacter < CharacterClassSingleCharacter
      def initialize(data)
        super character: Compiler.translate_escaped_character(data[:character])
      end
    end
    
    class CharacterClassRange < ParsingExpression
      def build(builder, start_input, successful_block, failed_block)
        input_char = builder.load start_input, "char"
        expectation = "#{@data[:begin_char].data[:character]}-#{@data[:end_char].data[:character]}"
        begin_char_successful = builder.create_block "character_class_range_begin_char_successful"
        successful = builder.icmp :uge, input_char, LLVM::Int8.from_i(@data[:begin_char].data[:character].ord), "begin_matching"
        builder.cond successful, begin_char_successful, builder.trace_failure_reason(failed_block, start_input, expectation)
        builder.position_at_end begin_char_successful
        successful = builder.icmp :ule, input_char, LLVM::Int8.from_i(@data[:end_char].data[:character].ord), "end_matching"
        builder.cond successful, successful_block, builder.trace_failure_reason(failed_block, start_input, expectation)
      end
    end
  end
end