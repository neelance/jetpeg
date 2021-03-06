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
        c = unescape_char(@_data[:char])
        if not @_data[:case_sensitive] and c.swapcase != c # TODO transform to DSL
          successful1 = icmp :eq, load(@_start_input), LLVM::Int8.from_i(c.downcase.ord)
          successful2 = icmp :eq, load(@_start_input), LLVM::Int8.from_i(c.upcase.ord)
          successful = self.or successful1, successful2
          cond successful, :_successful, :_failed
        else
          successful = icmp :eq, load(@_start_input), character_byte(:char)
          cond successful, :_successful, :_failed
        end
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
        @successful = icmp :eq, @input_char, character_byte(:char)
        cond @successful, :_successful, :_failed
      end

      block :_failed do
        trace_failure @_start_input, string(:char), LLVM::TRUE if @_traced
      end
    end
    
    class CharacterClassRange < ParsingExpression
      block :_entry do
        @input_char = load @_start_input, "char"
        @successful = icmp :uge, @input_char, character_byte(:begin_char)
        cond @successful, :begin_char_successful, :_failed
      end
    
      block :begin_char_successful do
        @successful = icmp :ule, @input_char, character_byte(:end_char)
        cond @successful, :_successful, :_failed
      end

      block :_failed do
        trace_failure @_start_input, string("#{@_data[:begin_char]}-#{@_data[:end_char]}"), LLVM::TRUE if @_traced
      end
    end
  end
end