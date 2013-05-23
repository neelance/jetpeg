module JetPEG
  module Compiler
    class StringTerminal < ParsingExpression
      def build(builder, start_input, modes, failed_block)
        end_input, _ = @data[:chars].build builder, start_input, modes, failed_block
        return end_input, false
      end
    end

    class CharacterSequence < ParsingExpression
      leftmost_leaves :char

      def build(builder, start_input, modes, failed_block)
        char_end_input, _ = @data[:char].build builder, start_input, modes, failed_block
        end_input, _ = @data[:rest].build builder, char_end_input, modes, failed_block
        return end_input, false
      end
    end

    class Character < ParsingExpression
      leftmost_leaves :self

      def build(builder, start_input, modes, failed_block)
        successful_block = builder.create_block "successful"

        char = @data[:char].gsub(/\\./) { |str| Compiler.translate_escaped_character str[1] }
        successful = builder.icmp :eq, builder.load(start_input), LLVM::Int8.from_i(char.ord), "failed"
        builder.cond successful, successful_block, failed_block #builder.trace_failure_reason(failed_block, start_input, string)
        
        builder.position_at_end successful_block
        end_input = builder.gep start_input, LLVM::Int(1), "new_input"
        return end_input, false
      end
    end
    
    class CharacterClassTerminal < ParsingExpression
      leftmost_leaves :self

      def build(builder, start_input, modes, failed_block)
        matched_block = builder.create_block "character_class_matched"
        successful_block = builder.create_block "character_class_successful"
        
        @data[:selections].each do |selection|
          next_selection_block = builder.create_block "character_class_next_selection"
          selection.build builder, start_input, modes, next_selection_block
          builder.br matched_block
          builder.position_at_end next_selection_block
        end
        builder.br(@data[:inverted] ? successful_block : failed_block)

        builder.position_at_end matched_block
        builder.br(@data[:inverted] ? failed_block : successful_block)

        builder.position_at_end successful_block
        end_input = builder.gep start_input, LLVM::Int(1), "new_input"
        return end_input, false
      end
    end
    
    class CharacterClassSingleCharacter < ParsingExpression
      block :_entry do
        @input_char = load @_start_input, "char"
        @successful = icmp :eq, @input_char, LLVM::Int8.from_i(@_data[:character].ord)
        @_builder.cond @successful, @_blocks[:_successful], @_builder.trace_failure_reason(@_blocks[:_failed], @_start_input, @_data[:character])
      end
    end
    
    class CharacterClassEscapedCharacter < CharacterClassSingleCharacter
      copy_blocks CharacterClassSingleCharacter

      def initialize(data)
        super character: Compiler.translate_escaped_character(data[:character])
      end
    end
    
    class CharacterClassRange < ParsingExpression
      block :_entry do
        @input_char = load @_start_input, "char"
        @expectation = "#{@_data[:begin_char].data[:character]}-#{@_data[:end_char].data[:character]}"
        @successful = icmp :uge, @input_char, LLVM::Int8.from_i(@_data[:begin_char].data[:character].ord)
        @_builder.cond @successful, @_blocks[:begin_char_successful], @_builder.trace_failure_reason(@_blocks[:_failed], @_start_input, @expectation)
      end
      
      block :begin_char_successful do
        @successful = icmp :ule, @input_char, LLVM::Int8.from_i(@_data[:end_char].data[:character].ord)
        @_builder.cond @successful, @_blocks[:_successful], @_builder.trace_failure_reason(@_blocks[:_failed], @_start_input, @expectation)
      end
    end
  end
end