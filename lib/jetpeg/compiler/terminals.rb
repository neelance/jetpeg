module JetPEG
  module Compiler
    class StringTerminal < ParsingExpression
      block :_entry do
        @_end_input, _ = build :chars, @_start_input, :_failed
        br :_successful
      end
    end

    class CharacterSequence < ParsingExpression
      leftmost_leaves :char

      block :_entry do
        @char_end_input, _ = build :char, @_start_input, :_failed
        @_end_input, _ = build :rest, @char_end_input, :_failed
        br :_successful
      end
    end

    class Character < ParsingExpression
      leftmost_leaves :self

      block :_entry do
        @char = @_data[:char].gsub(/\\./) { |str| Compiler.translate_escaped_character str[1] }
        successful = icmp :eq, load(@_start_input), LLVM::Int8.from_i(@char.ord)
        cond successful, :_successful, :_failed
      end
        
      block :_successful do
        @_end_input = gep @_start_input, LLVM::Int(1)
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