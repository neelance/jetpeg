require "treetop"
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
LLVM_STRING = LLVM::Pointer(LLVM::Int8)

require "jetpeg/compiler/metagrammar"
require "jetpeg/runtime"
require "jetpeg/label_value"

module JetPEG
  module Compiler
    def self.parse(code, root)
      metagrammar_parser = MetagrammarParser.new
      result = metagrammar_parser.parse code, :root => root
      raise metagrammar_parser.failure_reason if result.nil?
      result
    end
    
    def self.compile_rule(code)
      expression = parse code, :choice
      expression.mod = LLVM::Module.create "Parser"
      expression.rule_label_type # check label types
      expression
    end
    
    def self.compile_grammar(code)
      rules = parse(code, :grammar).rules
      mod = LLVM::Module.create "Parser"
      Grammar.new mod, rules
    end
    
    class PhiGenerator
      def initialize(builder, type, name = "")
        @builder = builder
        @type = type
        @name = name
        @values = {}
      end
      
      def <<(value)
        @values[@builder.insert_block] = value || @type.null
      end
      
      def generate
        @builder.phi @type, @values, @name
      end
    end
        
    class Result
      attr_accessor :input, :labels
      
      def initialize(input = nil)
        @input = input
        @labels = {}
      end
      
      def merge!(result)
        @input = result.input
        @labels.merge! result.labels
        self
      end
    end
    
    class BranchingResult < Result
      def initialize(builder, label_types)
        @input_phi = PhiGenerator.new builder, LLVM_STRING, "input"
        @label_phis = label_types.each_with_object({}) { |(name, type), h| h[name] = PhiGenerator.new builder, type.llvm_type, name.to_s }
      end
      
      def <<(result)
        @input_phi << result.input
        @label_phis.each { |name, phi| phi << result.labels[name] }
      end
      
      def generate
        @input = @input_phi.generate
        @labels = @label_phis.each_with_object({}) { |(name, phi), h| h[name] = phi.generate }
        self
      end
    end
    
    class Grammar
      attr_reader :mod, :malloc
      
      def initialize(mod, rules)
        @mod = mod
        @malloc = @mod.functions.add "malloc", [LLVM::Int], LLVM::Pointer(LLVM::Int8)
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
      
      def label_types
        {}
      end
      
      def rule_label_type
        if @rule_label_type.nil?
          @rule_label_type = HashLabelValueType.new label_types
        end
        @rule_label_type
      end
      
      def rule_function
        @rule_function ||= @mod.functions.add(@name, [LLVM_STRING, LLVM::Pointer(rule_label_type.llvm_type)], LLVM_STRING) do |function, input, data_ptr|
          @rule_function = function
          entry = function.basic_blocks.append "entry"
          builder = LLVM::Builder.create
          builder.position_at_end entry
  
          failed_block = builder.create_block "failed"
          end_result = build builder, input, failed_block
          
          unless rule_label_type.empty?
            data = rule_label_type.create_value builder, end_result.labels
            builder.store data, data_ptr
          end
          
          builder.ret end_result.input
  
          builder.position_at_end failed_block
          builder.ret LLVM_STRING.null_pointer
          
          function.linkage = :private
        end
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
        data = !rule_label_type.empty? && rule_label_type.ffi_type.new
        input_end_ptr = execution_engine.run_function(rule_function, input_ptr, data && data.pointer).to_value_ptr
        
        if input_ptr.address + input.size == input_end_ptr.address
          rule_label_type.read data, input, input_ptr.address
        else
          nil
        end
      end
    end
    
    class Sequence < ParsingExpression
      def children
        @children ||= [head] + tail.elements
      end
      
      def label_types
        @label_types ||= children.map(&:label_types).each_with_object({}) { |types, total|
          total.merge!(types) { |key, oldval, newval|
            raise SyntaxError, "Duplicate label."
          }
        }
      end
      
      def build(builder, start_input, failed_block)
        children.inject(Result.new(start_input)) do |result, child|
          result.merge! child.build(builder, result.input, failed_block)
        end
      end
    end
    
    class Choice < ParsingExpression
      def children
        @children ||= [head] + tail.elements.map(&:alternative)
      end
      
      def label_types
        @label_types ||= children.map(&:label_types).each_with_object({}) { |types, total|
          total.merge!(types) { |key, oldval, newval|
            raise SyntaxError, "Incompatible label types." if oldval != newval
            oldval
          }
        }
      end
      
      def build(builder, start_input, failed_block)
        successful_block = builder.create_block "choice_successful"
        child_blocks = children.map { builder.create_block "choice_child" }
        result = BranchingResult.new builder, label_types
        builder.br child_blocks.first
        
        children.each_with_index do |child, index|
          builder.position_at_end child_blocks[index]
          result << child.build(builder, start_input, child_blocks[index + 1] || failed_block)
          builder.br successful_block
        end
        
        builder.position_at_end successful_block
        result.generate
      end
    end
    
    class Optional < ParsingExpression
      def label_types
        expression.label_types
      end
      
      def build(builder, start_input, failed_block)
        exit_block = builder.create_block "optional_exit"
        result = BranchingResult.new builder, label_types
        
        optional_failed_block = builder.create_block "optional_failed"
        result << expression.build(builder, start_input, optional_failed_block)
        builder.br exit_block
        
        builder.position_at_end optional_failed_block
        result << Result.new(start_input)
        builder.br exit_block
        
        builder.position_at_end exit_block
        result.generate
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
        next_result = expression.build builder, input, exit_block
        input.add_incoming builder.insert_block => next_result.input
        builder.br loop_block
        
        builder.position_at_end exit_block
        Result.new input
      end
    end
    
    class OneOrMore < ZeroOrMore
      def build(builder, start_input, failed_block)
        result = expression.build builder, start_input, failed_block
        super builder, result.input, failed_block
      end
    end
    
    class PositiveLookahead < ParsingExpression
      def build(builder, start_input, failed_block)
        expression.build builder, start_input, failed_block
        Result.new start_input
      end
    end
    
    class NegativeLookahead < ParsingExpression
      def build(builder, start_input, failed_block)
        lookahead_failed_block = builder.create_block "lookahead_failed"

        expression.build builder, start_input, lookahead_failed_block
        builder.br failed_block
        
        builder.position_at_end lookahead_failed_block
        Result.new start_input
      end
    end
            
    class AnyCharacterTerminal < ParsingExpression
      def build(builder, start_input, failed_block)
        end_input = builder.gep start_input, LLVM::Int(1), "new_input"
        Result.new end_input
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
        Result.new end_input
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
        Result.new end_input
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
      def referenced
        @referenced ||= grammar[name.text_value]
      end
      
      def referenced_label_type
        if @referenced_label_type.nil?
          @recursion ||= false
          if @recursion
            @referenced_label_type = HashLabelValueType.new({})
          else
            @recursion = true
            if @label_type.nil? # no recursion
              @referenced_label_type = referenced.rule_label_type
            end
          end
        end
        @referenced_label_type
      end
      
      def label_types
        referenced_label_type.types
      end
      
      def build(builder, start_input, failed_block)
        label_data_ptr = builder.alloca referenced_label_type.llvm_type, "label_data_ptr"
        rule_end_input = builder.call referenced, start_input, label_data_ptr, "rule_end_input"
        
        rule_successful = builder.icmp :ne, rule_end_input, LLVM_STRING.null_pointer, "rule_successful"
        successful_block = builder.create_block "rule_call_successful"
        builder.cond rule_successful, successful_block, failed_block
        
        builder.position_at_end successful_block
        label_data = builder.load label_data_ptr, "label_data"
        result = Result.new rule_end_input
        label_types.each_with_index do |(name, type), index|
          result.labels[name] = builder.extract_value label_data, index, name.to_s
        end
        result
      end
    end
    
    class ParenthesizedExpression < ParsingExpression
      def label_types
        expression.label_types
      end
      
      def build(builder, start_input, failed_block)
        expression.build builder, start_input, failed_block
      end
    end
    
    class Label < ParsingExpression
      def label_type
        if @label_type.nil?
          @recursion ||= false
          if @recursion
            @label_type = PointerLabelValueType.new grammar.malloc, expression
          else
            @recursion = true
            inner_label_types = expression.label_types
            if @label_type.nil? # no recursion
              @label_type = if inner_label_types.empty?
                TerminalLabelValueType::INSTANCE
              else
                HashLabelValueType.new inner_label_types
              end
            end
          end
        end
        @label_type
      end
      
      def label_types
        { name.text_value.to_sym => label_type }
      end
      
      def build(builder, start_input, failed_block)
        result = expression.build builder, start_input, failed_block
        value = label_type.create_value builder, result.labels, start_input, result.input
        result.labels = { name.text_value.to_sym => value }
        result
      end
    end
  end
end