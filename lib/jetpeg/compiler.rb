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
    
    class Grammar
      def initialize(mod, rules)
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
    end
    
    class ParsingExpression < Treetop::Runtime::SyntaxNode
      attr_accessor :name, :mod, :own_method_requested, :recursive, :reference_count
      
      def initialize(*args)
        super
        @own_method_requested = false
        @recursive = false
        @reference_count = 0
        @rule_function = nil
        @parse_function = nil
      end
      
      def grammar
        element = parent
        element = element.parent while not element.is_a?(Grammar)
        element
      end
      
      def mark_recursions(inside_expressions)
        return if @recursive
        
        if inside_expressions.include? self
          raise if @name.nil?
          @recursive = true
          return
        end
        
        children.each do |child|
          child.mark_recursions inside_expressions + [self]
        end
      end
      
      def has_own_method?
        @own_method_requested || @recursive || @reference_count >= 10
      end
      
      def fixed_length # TODO remove if not necessary any more
        nil
      end
      
      def rule_function
        if @rule_function.nil?
          @mod.functions.add(@name, [LLVM_STRING], LLVM_STRING) do |function, input|
            @rule_function = function # set here to avoid infinite recursion
            entry = function.basic_blocks.append "entry"
            builder = LLVM::Builder.create
            builder.position_at_end entry
    
            failed_block = builder.create_block "failed"
            rule_end_input = build builder, input, failed_block
            builder.ret rule_end_input
    
            builder.position_at_end failed_block
            builder.ret LLVM_STRING.null_pointer
            
            function.verify 
          end
        end
        @rule_function
      end
      
      def match(parse_input)
        if @parse_function.nil?
          @parse_function = @mod.functions.add("parse", [LLVM_STRING, LLVM::Int], LLVM::Int1) do |function, input, length|
            entry = function.basic_blocks.append "entry"
            builder = LLVM::Builder.create
            builder.position_at_end entry
            
            rule_end_input = builder.call rule_function, input
            real_end_input = builder.gep input, length, "input_end"
            at_end = builder.icmp :eq, rule_end_input, real_end_input, "at_end"
            builder.ret at_end
            
            function.verify
          end
    
          @mod.verify
          
          @engine = LLVM::ExecutionEngine.create_jit_compiler @mod
    
          optimize = false
          if optimize
            pass_manager = LLVM::PassManager.new @engine
            pass_manager.inline!
            pass_manager.instcombine!
            pass_manager.reassociate!
            pass_manager.gvn!
            pass_manager.simplifycfg!
            pass_manager.run @mod
          end
        end
  
        input_ptr = FFI::MemoryPointer.from_string parse_input
        @engine.run_function(@parse_function, input_ptr, parse_input.size).to_b
      end
    end
    
    class Sequence < ParsingExpression
      def children
        @children ||= ([head] + tail.elements).map { |child| child.expression }
      end
      
      def fixed_length
        @fixed_length ||= begin
          lengths = children.map(&:fixed_length)
          lengths.all? ? lengths.reduce(0, :+) : nil
        end
      end
      
      def build(builder, start_input, failed_block)
        children.inject(start_input) do |input, child|
          child.build builder, input, failed_block
        end
      end
    end
    
    class Choice < ParsingExpression
      def children
        @children ||= [head] + tail.elements.map(&:alternative)
      end
      
      def fixed_length
        @fixed_length ||= begin
          lengths = children.map(&:fixed_length).uniq
          lengths.size == 1 ? lengths.first : nil
        end
      end
      
      def build(builder, start_input, failed_block)
        successful_block = builder.create_block "choice_successful"
        phi_values = {}
        
        children.each do |child|
          next_child_block = builder.create_block "choice_next_child"
          input = child.build builder, start_input, next_child_block
          phi_values[builder.insert_block] = input
          builder.br successful_block
          
          builder.position_at_end next_child_block
        end
        builder.br failed_block
        
        builder.position_at_end successful_block
        builder.phi LLVM_STRING, phi_values, "choice_end_input"
      end
    end
    
    class Optional < ParsingExpression
      def children
        [expression]
      end
      
      def build(builder, start_input, failed_block)
        exit_block = builder.create_block "optional_exit"
        
        optional_failed_block = builder.create_block "optional_failed"
        input = expression.build builder, start_input, optional_failed_block
        optional_successful_block = builder.insert_block
        builder.br exit_block
        
        builder.position_at_end optional_failed_block
        builder.br exit_block
        
        builder.position_at_end exit_block
        builder.phi LLVM_STRING, { optional_failed_block => start_input, optional_successful_block => input }, "optional_end_input"
      end
    end
    
    class ZeroOrMore < ParsingExpression
      def children
        [expression]
      end
      
      def build(builder, start_input, failed_block)
        start_block = builder.insert_block
        loop_block = builder.create_block "repetition_loop"
        exit_block = builder.create_block "repetition_exit"
        builder.br loop_block
        
        builder.position_at_end loop_block
        input = builder.phi LLVM_STRING, { start_block => start_input }, "loop_input"
        next_input = expression.build builder, input, exit_block
        input.add_incoming builder.insert_block => next_input
        builder.br loop_block
        
        builder.position_at_end exit_block
        input
      end
    end
    
    class OneOrMore < ZeroOrMore
      def build(builder, start_input, failed_block)
        input = expression.build builder, start_input, failed_block
        super builder, input, failed_block
      end
    end
    
    class Lookahead < ParsingExpression
      def children
        [expression]
      end
      
      def fixed_length
        0
      end
    end
    
    class PositiveLookahead < Lookahead
      def build(builder, start_input, failed_block)
        expression.build builder, start_input, failed_block
        start_input
      end
    end
    
    class NegativeLookahead < Lookahead
      def build(builder, start_input, failed_block)
        lookahead_failed_block = builder.create_block "lookahead_failed"

        expression.build builder, start_input, lookahead_failed_block
        builder.br failed_block
        
        builder.position_at_end lookahead_failed_block
        start_input
      end
    end
    
    class Terminal < ParsingExpression
      def children
        []
      end
    end
        
    class AnyCharacterTerminal < Terminal
      def fixed_length
        1
      end
      
      def build(builder, start_input, failed_block)
        builder.gep start_input, LLVM::Int(1), "new_input"
      end
    end
    
    class StringTerminal < Terminal
      def string
        @string ||= eval text_value # TODO avoid eval here
      end
      
      def fixed_length
        string.size
      end
      
      def build(builder, start_input, failed_block)
        string.chars.inject(start_input) do |input, char|
          input_char = builder.load input, "char"
          matching = builder.icmp :eq, input_char, LLVM::Int8.from_i(char.ord), "matching"
          next_char_block = builder.create_block "string_terminal_next_char"
          builder.cond matching, next_char_block, failed_block
          
          builder.position_at_end next_char_block
          builder.gep input, LLVM::Int(1), "new_input"
        end
      end
    end
    
    class CharacterClassTerminal < Terminal
      def pattern
        characters.text_value
      end
      
      def fixed_length
        1
      end
      
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
        
        builder.gep start_input, LLVM::Int(1), "new_input"
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
      def referenced_expression
        @referenced_expression ||= begin
          exp = grammar.find_expression name.text_value
          exp.reference_count += 1
          exp
        end
      end
      
      def children
        [referenced_expression]
      end
      
      def fixed_length
        referenced_expression.recursive ? nil : referenced_expression.fixed_length
      end

      def build(builder, start_input, failed_block)
        rule_end_input = builder.call grammar[name.text_value].rule_function, start_input
        rule_successful = builder.icmp :ne, rule_end_input, LLVM_STRING.null_pointer, "rule_successful"
        successful_block = builder.create_block "rule_call_successful"
        builder.cond rule_successful, successful_block, failed_block
        builder.position_at_end successful_block
        rule_end_input
      end
    end
    
    class ParenthesizedExpression < ParsingExpression
      def children
        [expression]
      end
      
      def fixed_length
        expression.fixed_length
      end
      
      def build(builder, start_input, failed_block)
        expression.build builder, start_input, failed_block
      end
    end
  end
end