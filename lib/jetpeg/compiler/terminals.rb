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
          failed = builder.icmp :ne, builder.load(input), LLVM::Int8.from_i(char.ord), "failed"
          builder.add_failure_reason failed, start_input, ParsingError.new([@string])
          next_char_block = builder.create_block "string_terminal_next_char"
          builder.cond failed, failed_block, next_char_block
          
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
        failed = builder.icmp :ne, input_char, LLVM::Int8.from_i(character.ord), "matching"
        builder.add_failure_reason failed, start_input, ParsingError.new([character])
        builder.cond failed, failed_block, successful_block
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
        error = ParsingError.new(["#{@begin_char}-#{@end_char}"])
        begin_char_successful = builder.create_block "character_class_range_begin_char_successful"
        failed = builder.icmp :ult, input_char, LLVM::Int8.from_i(@begin_char.ord), "begin_matching"
        builder.add_failure_reason failed, start_input, error
        builder.cond failed, failed_block, begin_char_successful
        builder.position_at_end begin_char_successful
        failed = builder.icmp :ugt, input_char, LLVM::Int8.from_i(@end_char.ord), "end_matching"
        builder.add_failure_reason failed, start_input, error
        builder.cond failed, failed_block, successful_block
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