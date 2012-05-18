module JetPEG
  module Compiler
    class StringTerminal < Primary
      attr_reader :string
      
      def initialize(data)
        super()
        @string = data[:string].gsub(/\\./) { |str| Compiler.translate_escaped_character str[1] }
      end
      
      def build(builder, start_input, modes, failed_block)
        end_input = @string.chars.inject(start_input) do |input, char|
          successful = builder.icmp :eq, builder.load(input), LLVM::Int8.from_i(char.ord), "failed"
          next_char_block = builder.create_block "string_terminal_next_char"
          builder.cond successful, next_char_block, builder.add_failure_reason(failed_block, start_input, @string)
          
          builder.position_at_end next_char_block
          builder.gep input, LLVM::Int(1), "new_input"
        end
        Result.new end_input
      end
      
      def ==(other)
        other.is_a?(StringTerminal) && other.string == @string
      end
    end
    
    class CharacterClassTerminal < Primary
      attr_reader :selections, :inverted
      
      def initialize(data)
        super()
        @selections = data[:selections]
        @inverted = data[:inverted]
      end

      def build(builder, start_input, modes, failed_block)
        input_char = builder.load start_input, "char"
        successful_block = builder.create_block "character_class_successful" unless @inverted
        
        @selections.each do |selection|
          next_selection_block = builder.create_block "character_class_next_selection"
          selection.build builder, start_input, input_char, (@inverted ? failed_block : successful_block), next_selection_block
          builder.position_at_end next_selection_block
        end
        
        unless @inverted
          builder.br failed_block
          builder.position_at_end successful_block
        end
        
        end_input = builder.gep start_input, LLVM::Int(1), "new_input"
        Result.new end_input
      end
      
      def ==(other)
        other.is_a?(CharacterClassTerminal) && other.selections == @selections && other.inverted == @inverted
      end
    end
    
    class CharacterClassSingleCharacter
      attr_reader :character
      
      def initialize(data)
        @character = data[:char_element]
      end
      
      def build(builder, start_input, input_char, successful_block, failed_block)
        successful = builder.icmp :eq, input_char, LLVM::Int8.from_i(character.ord), "matching"
        builder.cond successful, successful_block, builder.add_failure_reason(failed_block, start_input, character)
      end
      
      def ==(other)
        other.is_a?(CharacterClassSingleCharacter) && other.character == @character
      end
    end
    
    class CharacterClassEscapedCharacter < CharacterClassSingleCharacter
      def initialize(data)
        super
        @character = Compiler.translate_escaped_character data[:char_element]
      end
    end
    
    class CharacterClassRange
      attr_reader :begin_char, :end_char
      
      def initialize(data)
        @begin_char = data[:begin_char].character
        @end_char = data[:end_char].character
      end

      def build(builder, start_input, input_char, successful_block, failed_block)
        expectation = "#{@begin_char}-#{@end_char}"
        begin_char_successful = builder.create_block "character_class_range_begin_char_successful"
        successful = builder.icmp :uge, input_char, LLVM::Int8.from_i(@begin_char.ord), "begin_matching"
        builder.cond successful, begin_char_successful, builder.add_failure_reason(failed_block, start_input, expectation)
        builder.position_at_end begin_char_successful
        successful = builder.icmp :ule, input_char, LLVM::Int8.from_i(@end_char.ord), "end_matching"
        builder.cond successful, successful_block, builder.add_failure_reason(failed_block, start_input, expectation)
      end
      
      def ==(other)
        other.is_a?(CharacterClassRange) && other.begin_char == @begin_char && other.end_char == @end_char
      end
    end
    
    class AnyCharacterTerminal < CharacterClassTerminal
      SELECTIONS = [CharacterClassSingleCharacter.new({ char_element: "\0" })]
      
      def initialize(data)
        super({})
        @selections = SELECTIONS
        @inverted = true
      end
    end
  end
end