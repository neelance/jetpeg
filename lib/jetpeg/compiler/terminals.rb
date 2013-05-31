module JetPEG
  module Compiler
    class StringTerminal < ParsingExpression
      leftmost_leaves :self

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
        successful = icmp :eq, load(@_start_input), LLVM::Int8.from_i(Compiler.unescape_character(@_data[:char]).ord)
        cond successful, :_successful, :_failed
      end
        
      block :_successful do
        @_end_input = gep @_start_input, LLVM::Int(1)
      end
    end
    
    class CharacterClassTerminal < ParsingExpression
      leftmost_leaves :self

      block :_entry do
        build :selection, @_start_input, :no_match
        br :_successful if not @_data[:inverted]
        br :_failed if @_data[:inverted]
      end

      block :no_match do
        br :_failed if not @_data[:inverted]
        br :_successful if @_data[:inverted]
      end

      block :_successful do
        @_end_input = gep @_start_input, LLVM::Int(1)
      end
    end

    class CharacterClassSelection < ParsingExpression
      block :_entry do
        build :selector, @_start_input, :no_match
        br :_successful
      end

      block :no_match do
        build :rest, @_start_input, :_failed
        br :_successful
      end
    end
    
    class CharacterClassSingleCharacter < ParsingExpression
      block :_entry do
        @input_char = load @_start_input, "char"
        @successful = icmp :eq, @input_char, LLVM::Int8.from_i(Compiler.unescape_character(@_data[:character]).ord)
        @_builder.cond @successful, @_blocks[:_successful], @_builder.trace_failure_reason(@_blocks[:_failed], @_start_input, @_data[:character])
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