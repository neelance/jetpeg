require "treetop"
require "jetpeg/compiler/metagrammar"

require 'llvm/core'
require 'llvm/execution_engine'
require 'llvm/transforms/scalar'
require 'llvm/transforms/ipo'

module LLVM
  TRUE = LLVM::Int1.from_i(-1)
  FALSE = LLVM::Int1.from_i(0)
  
  class Builder
    def create_block(name)
      LLVM::BasicBlock.create self.insert_block.parent, name
    end
  end
end

LLVM.init_x86

module JetPEG
  module Compiler
    LLVM_STRING = LLVM::Pointer(LLVM::Int8)
    LLVM_POSITION = LLVM::Struct(LLVM_STRING, LLVM_STRING)
    
    FFI_POSITION = Class.new FFI::Struct
    FFI_POSITION.layout :begin, :pointer, :end, :pointer
    
    def self.parse(code, root)
      metagrammar_parser = MetagrammarParser.new
      result = metagrammar_parser.parse code, :root => root
      raise metagrammar_parser.failure_reason if result.nil?
      result
    end
    
    def self.compile_rule(code)
      expression = parse code, :choice
      expression.mod = LLVM::Module.create "Parser"
      expression
    end
    
    def self.compile_grammar(code)
      rules = parse(code, :grammar).rules
      mod = LLVM::Module.create "Parser"
      Grammar.new mod, rules
    end
    
    class PhiGenerator
      def initialize(builder, type)
        @builder = builder
        @type = type
        @values = {}
      end
      
      def <<(value)
        @values[@builder.insert_block] = value
      end
      
      def fill_blocks(blocks)
        blocks.each { |block| @values[block] ||= @type.null }
      end
      
      def generate(name = "")
        @builder.phi @type, @values, name
      end
    end
    
    class PhiGeneratorHash
      def initialize(builder, type)
        @builder = builder
        @phis = Hash.new { |h, k| h[k] = PhiGenerator.new(builder, type) }
        @blocks = []
      end
      
      def merge!(hash)
        @blocks << @builder.insert_block
        hash.each { |name, value| @phis[name] << value }
      end
      
      def generate
        Hash[@phis.map{ |name, phi| phi.fill_blocks @blocks; [name, phi.generate(name.to_s)] }]
      end
    end
    
    class State
      attr_accessor :input, :labels
      
      def initialize(input = nil)
        @input = input
        @labels = {}
      end
      
      def merge!(state)
        @input = state.input
        @labels.merge! state.labels
        self
      end
    end
    
    class BranchingState < State
      def initialize(builder)
        @input_phi = PhiGenerator.new builder, LLVM_STRING
        @label_phis = PhiGeneratorHash.new builder, LLVM_POSITION
      end
      
      def <<(state)
        @input_phi << state.input
        @label_phis.merge! state.labels
      end
      
      def generate
        @input = @input_phi.generate "input"
        @labels = @label_phis.generate
        self
      end
    end
    
    class Grammar
      attr_reader :mod
      
      def initialize(mod, rules)
        @mod = mod
        @rules = {}
        rules.elements.each do |element|
          expression = element.expression
          expression.name = element.rule_name.name.text_value
          expression.mod = mod
          expression.parent = self
          @rules[expression.name] = expression
        end
      end
      
      def [](name)
        @rules[name]
      end
      
      def parse(code)
        @rules.values.first.match code
      end
      
      def optimize!
        @rules.values.first.optimize!
      end
    end
    
    class DummyBuilder
      def phi(*args)
        self
      end
      
      def method_missing(name, *args)
        # ignore
      end
    end
    
    class RuleDataStructure
      attr_reader :labels, :llvm_type, :ffi_type
      
      def initialize(labels)
        @labels = labels
        
        @llvm_type = LLVM::Struct(*([LLVM_POSITION] * labels.size))
        
        @ffi_type = Class.new FFI::Struct
        @ffi_type.layout(*labels.map{ |name| [name, FFI_POSITION] }.flatten)
      end
      
      def empty?
        @labels.empty?
      end
    end
        
    class ParsingExpression < Treetop::Runtime::SyntaxNode
      attr_accessor :name, :mod
      
      def initialize(*args)
        super
        @rule_function = nil
        @parse_function = nil
        @execution_engine = nil
      end
      
      def grammar
        element = parent
        element = element.parent while not element.is_a?(Grammar)
        element
      end
      
      def data_structure
        @data_structure ||= begin
          @data_structure = RuleDataStructure.new [] # avoid recursion
          dummy_state = build DummyBuilder.new, nil, nil
          RuleDataStructure.new dummy_state.labels.keys
        end
      end
      
      def rule_function
        if @rule_function.nil?
          @mod.functions.add(@name, [LLVM_STRING, LLVM::Pointer(data_structure.llvm_type)], LLVM_STRING) do |function, input, data_ptr|
            @rule_function = function
            entry = function.basic_blocks.append "entry"
            builder = LLVM::Builder.create
            builder.position_at_end entry
    
            failed_block = builder.create_block "failed"
            end_state = build builder, input, failed_block
            
            unless data_structure.empty?
              data = data_structure.llvm_type.null
              end_state.labels.each_with_index do |(name, pos), index|
                data = builder.insert_value data, pos, index
              end
              data = builder.store data, data_ptr
            end
            
            builder.ret end_state.input
    
            builder.position_at_end failed_block
            builder.ret LLVM_STRING.null_pointer
          end
          @rule_function.linkage = :private
        end
        @rule_function
      end
      
      def to_ptr
        rule_function.to_ptr
      end
      
      def execution_engine
        if @execution_engine.nil?
          rule_function.linkage = :external
          @mod.verify!
          @execution_engine = LLVM::ExecutionEngine.create_jit_compiler @mod
        end
        @execution_engine
      end
      
      def optimize!
        @execution_engine = nil
        pass_manager = LLVM::PassManager.new execution_engine
        pass_manager.inline!
        pass_manager.instcombine!
        pass_manager.reassociate!
        pass_manager.gvn!
        pass_manager.simplifycfg!
        pass_manager.run @mod
      end
      
      def match(input)
        input_ptr = FFI::MemoryPointer.from_string input
        data = !data_structure.empty? && data_structure.ffi_type.new
        input_end_ptr = execution_engine.run_function(rule_function, input_ptr, data && data.pointer).to_value_ptr
        
        if input_ptr.address + input.size == input_end_ptr.address
          values = {}
          data_structure.labels.each do |name|
            pos = data[name]
            values[name] = input[(pos[:begin].address - input_ptr.address)...(pos[:end].address - input_ptr.address)]
          end
          values
        else
          nil
        end
      end
    end
    
    class Sequence < ParsingExpression
      def children
        @children ||= [head] + tail.elements
      end
      
      def build(builder, start_input, failed_block)
        children.inject(State.new(start_input)) do |state, child|
          state.merge! child.build(builder, state.input, failed_block)
        end
      end
    end
    
    class Choice < ParsingExpression
      def children
        @children ||= [head] + tail.elements.map(&:alternative)
      end
      
      def build(builder, start_input, failed_block)
        successful_block = builder.create_block "choice_successful"
        child_blocks = children.map { builder.create_block "choice_child" }
        state = BranchingState.new builder
        builder.br child_blocks.first
        
        children.each_with_index do |child, index|
          builder.position_at_end child_blocks[index]
          state << child.build(builder, start_input, child_blocks[index + 1] || failed_block)
          builder.br successful_block
        end
        
        builder.position_at_end successful_block
        state.generate
      end
    end
    
    class Optional < ParsingExpression
      def build(builder, start_input, failed_block)
        exit_block = builder.create_block "optional_exit"
        state = BranchingState.new builder
        
        optional_failed_block = builder.create_block "optional_failed"
        state << expression.build(builder, start_input, optional_failed_block)
        builder.br exit_block
        
        builder.position_at_end optional_failed_block
        state << State.new(start_input)
        builder.br exit_block
        
        builder.position_at_end exit_block
        state.generate
      end
    end
    
    class ZeroOrMore < ParsingExpression
       def build(builder, start_input, failed_block)
        start_block = builder.insert_block
        loop_block = builder.create_block "repetition_loop"
        exit_block = builder.create_block "repetition_exit"
        builder.br loop_block
        
        builder.position_at_end loop_block
        input = builder.phi LLVM_STRING, { start_block => start_input }, "loop_input"
        next_state = expression.build builder, input, exit_block
        input.add_incoming builder.insert_block => next_state.input
        builder.br loop_block
        
        builder.position_at_end exit_block
        State.new input
      end
    end
    
    class OneOrMore < ZeroOrMore
      def build(builder, start_input, failed_block)
        state = expression.build builder, start_input, failed_block
        super builder, state.input, failed_block
      end
    end
    
    class PositiveLookahead < ParsingExpression
      def build(builder, start_input, failed_block)
        expression.build builder, start_input, failed_block
        State.new start_input
      end
    end
    
    class NegativeLookahead < ParsingExpression
      def build(builder, start_input, failed_block)
        lookahead_failed_block = builder.create_block "lookahead_failed"

        expression.build builder, start_input, lookahead_failed_block
        builder.br failed_block
        
        builder.position_at_end lookahead_failed_block
        State.new start_input
      end
    end
            
    class AnyCharacterTerminal < ParsingExpression
      def build(builder, start_input, failed_block)
        end_input = builder.gep start_input, LLVM::Int(1), "new_input"
        State.new end_input
      end
    end
    
    class StringTerminal < ParsingExpression
      def string
        @string ||= eval text_value # TODO avoid eval here
      end
      
      def build(builder, start_input, failed_block)
        end_input = string.chars.inject(start_input) do |input, char|
          input_char = builder.load input, "char"
          matching = builder.icmp :eq, input_char, LLVM::Int8.from_i(char.ord), "matching"
          next_char_block = builder.create_block "string_terminal_next_char"
          builder.cond matching, next_char_block, failed_block
          
          builder.position_at_end next_char_block
          builder.gep input, LLVM::Int(1), "new_input"
        end
        State.new end_input
      end
    end
    
    class CharacterClassTerminal < ParsingExpression
      def build(builder, start_input, failed_block)
        is_inverted = !inverted.text_value.empty?
        input_char = builder.load start_input, "char"
        successful_block = builder.create_block "character_class_successful" unless is_inverted
        
        selections.elements.each do |selection|
          next_selection_block = builder.create_block "character_class_next_selection"
          selection.build builder, input_char, (is_inverted ? failed_block : successful_block), next_selection_block
          builder.position_at_end next_selection_block
        end
        
        unless is_inverted
          builder.br failed_block
          builder.position_at_end successful_block
        end
        
        end_input = builder.gep start_input, LLVM::Int(1), "new_input"
        State.new end_input
      end
    end
    
    class CharacterClassSingleCharacter < Treetop::Runtime::SyntaxNode
      def character
        char_element.text_value
      end
      
      def build(builder, input_char, successful_block, failed_block)
        matching = builder.icmp :eq, input_char, LLVM::Int8.from_i(character.ord), "matching"
        builder.cond matching, successful_block, failed_block
      end
    end
    
    class CharacterClassEscapedCharacter < CharacterClassSingleCharacter
      def character
        case char_element.text_value
        when "r" then "\r"
        when "n" then "\n"
        when "t" then "\t"
        else char_element.text_value
        end
      end
    end
    
    class CharacterClassRange < Treetop::Runtime::SyntaxNode
      def build(builder, input_char, successful_block, failed_block)
        begin_char_successful = builder.create_block "character_class_range_begin_char_successful"
        matching = builder.icmp :uge, input_char, LLVM::Int8.from_i(begin_char.character.ord), "begin_matching"
        builder.cond matching, begin_char_successful, failed_block
        builder.position_at_end begin_char_successful
        matching = builder.icmp :ule, input_char, LLVM::Int8.from_i(end_char.character.ord), "end_matching"
        builder.cond matching, successful_block, failed_block
      end
    end
    
    class RuleName < ParsingExpression
      def build(builder, start_input, failed_block)
        referenced = grammar[name.text_value]
        rule_end_input = builder.call referenced, start_input, LLVM::Pointer(referenced.data_structure.llvm_type).null_pointer
        rule_successful = builder.icmp :ne, rule_end_input, LLVM_STRING.null_pointer, "rule_successful"
        successful_block = builder.create_block "rule_call_successful"
        builder.cond rule_successful, successful_block, failed_block
        builder.position_at_end successful_block
        State.new rule_end_input
      end
    end
    
    class ParenthesizedExpression < ParsingExpression
      def build(builder, start_input, failed_block)
        expression.build builder, start_input, failed_block
      end
    end
    
    class Label < ParsingExpression
      def build(builder, start_input, failed_block)
        state = expression.build builder, start_input, failed_block
        pos = LLVM_POSITION.null
        pos = builder.insert_value pos, start_input, 0
        pos = builder.insert_value pos, state.input, 1
        state.labels[name.text_value.to_sym] = pos
        state
      end
    end
  end
end