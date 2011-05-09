require "treetop"
require 'llvm/core'
require 'llvm/execution_engine'
require 'llvm/transforms/scalar'
require 'llvm/transforms/ipo'

LLVM.init_x86
LLVM_STRING = LLVM::Pointer(LLVM::Int8)

class FFI::Struct
  def inspect
    "{ #{members.map{ |name| "#{name}=#{self[name].inspect}" }.join ", "} }"
  end
end

require "jetpeg/runtime"
require "jetpeg/parser"
require "jetpeg/label_value"
require "jetpeg/compiler/metagrammar"
require "jetpeg/compiler/tools"

module JetPEG
  class CompilationError < RuntimeError
    attr_accessor :rule
    
    def initialize(msg)
      @msg = msg
      @rule = nil
    end
    
    def to_s
      "In rule \"#{@rule ? @rule.name : '<unknown>'}\": #{@msg}"
    end
  end
  
  module Compiler
    class Builder < LLVM::Builder
      attr_accessor :parser, :traced
      
      def create_block(name)
        LLVM::BasicBlock.create self.insert_block.parent, name
      end
      
      def call_rule(rule, *args)
        self.call rule.rule_function(@traced), *args
      end
      
      def add_failure_reason(failed, position, reason)
        return if not @traced
        @parser.possible_failure_reasons << reason
        callback = self.load @parser.llvm_add_failure_reason_callback, "callback"
        self.call callback, failed, position, LLVM::Int(reason.__id__)
      end
    end

    def self.parse(code, root)
      metagrammar_parser = MetagrammarParser.new
      result = metagrammar_parser.parse code, :root => root
      raise metagrammar_parser.failure_reason if result.nil?
      result
    end
    
    def self.compile_rule(code)
      expression = parse code, :choice
      expression.name = :rule
      Parser.new({ "rule" => expression })
      expression
    end
    
    def self.compile_grammar(code)
      rule_elements = parse(code, :grammar).rules
      rules = rule_elements.elements.each_with_object({}) do |element, h|
        expression = element.expression
        expression.name = element.rule_name.name.text_value.to_sym
        h[expression.name] = expression
      end
      Parser.new rules
    end
    
    class ParsingExpression < Treetop::Runtime::SyntaxNode
      attr_accessor :name
      
      def initialize(*args)
        super
        @bare_rule_function = nil
        @traced_rule_function = nil
        @parse_function = nil
        @execution_engine = nil
        @parser = nil
      end
      
      def parser
        element = parent
        element = element.parent while not element.is_a?(Parser)
        element
      end
      
      def label_types
        {}
      end
      
      def rule_label_type
        @rule_label_type ||= label_types.empty? ? HashLabelValueType.new({}) : LabelValueType.for_types(label_types)
      rescue CompilationError => e
        e.rule ||= self
        raise e
      end
      
      def mod=(mod)
        @mod = mod
        @bare_rule_function = nil
        @traced_rule_function = nil
      end
      
      def rule_function(traced)
        return @bare_rule_function if not traced and @bare_rule_function
        return @traced_rule_function if traced and @traced_rule_function
        
        @mod.functions.add @name, [LLVM_STRING, LLVM::Pointer(rule_label_type.llvm_type)], LLVM_STRING do |function, input, data_ptr|
          function.linkage = :private
          if traced
            @traced_rule_function = function
          else
            @bare_rule_function = function
          end
          
          entry = function.basic_blocks.append "entry"
          builder = Builder.create
          builder.parser = parser
          builder.traced = traced
          builder.position_at_end entry
  
          failed_block = builder.create_block "failed"
          end_result = build builder, input, failed_block
          
          data = rule_label_type.create_value builder, end_result.labels
          builder.store data, data_ptr unless data.null?
          
          builder.ret end_result.input
  
          builder.position_at_end failed_block
          builder.ret LLVM_STRING.null_pointer
        end
      rescue CompilationError => e
        e.rule ||= self
        raise e
      end
      
      def match(input, raise_on_failure = true)
        parser.match_rule self, input, raise_on_failure
      end
    end
    
    class Label < ParsingExpression
      def label_type
        (@label_type ||= RecursionGuard.new(PointerLabelValueType.new(expression)) {
          LabelValueType.for_types(expression.label_types)
        }).value
      end
      
      def label_name
        name.text_value.to_sym
      end
      
      def label_types
        label_name ? { label_name => label_type } : {}
      end
      
      def build(builder, start_input, failed_block)
        result = expression.build builder, start_input, failed_block
        value = label_type.create_value builder, result.labels, start_input, result.input
        result.labels = { label_name => value }
        result
      end
    end
    
    class Sequence < ParsingExpression
      def label_types
        @label_types ||= children.elements.map(&:label_types).each_with_object({}) { |types, total|
          total.merge!(types) { |key, oldval, newval|
            raise CompilationError.new("Duplicate label.")
          }
        }
      end
      
      def build(builder, start_input, failed_block)
        children.elements.inject(Result.new(start_input)) do |result, child|
          result.merge! child.build(builder, result.input, failed_block)
        end
      end
    end
    
    class Choice < ParsingExpression
      def children
        @children ||= [head] + tail.elements.map(&:alternative)
      end
      
      def label_types
        @label_types ||= begin
          child_types = children.map(&:label_types)
          all_keys = child_types.map(&:keys).flatten.uniq
          types = {}
          all_keys.each do |key|
            types_for_label = child_types.map { |t| t[key] }
            reduced_types_for_label = types_for_label.compact.uniq
            
            types[key] = if reduced_types_for_label.size == 1
              reduced_types_for_label.first
            else
              ChoiceLabelValueType.new types_for_label
            end
          end
          types
        end
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
    
    class ZeroOrMore < Label
      def label_type
        @array_label_type ||= begin
          types = expression.label_types
          !types.empty? && ArrayLabelValueType.new(super)
        end
      end
      
      def label_name
        label_type && DelegateLabelValueType::SYMBOL
      end
      
      def build(builder, start_input, failed_block, start_label_value = nil)
        start_block = builder.insert_block
        loop_block = builder.create_block "repetition_loop"
        exit_block = builder.create_block "repetition_exit"
        builder.br loop_block
        
        builder.position_at_end loop_block
        input = builder.phi LLVM_STRING, { start_block => start_input }, "loop_input"
        label_value = builder.phi label_type.llvm_type, { start_block => start_label_value || label_type.llvm_type.null }, "loop_label_value" if label_type
        
        next_result = expression.build builder, input, exit_block
        input.add_incoming builder.insert_block => next_result.input
        label_value.add_incoming builder.insert_block => label_type.create_entry(builder, next_result.labels, label_value) if label_type
        
        builder.br loop_block
        
        builder.position_at_end exit_block
        result = Result.new input
        result.labels = { DelegateLabelValueType::SYMBOL => label_value } if label_type
        result
      end
    end
    
    class OneOrMore < ZeroOrMore
      def build(builder, start_input, failed_block)
        result = expression.build builder, start_input, failed_block
        label_value = label_type.create_entry(builder, result.labels, label_type.llvm_type.null) if label_type
        super builder, result.input, failed_block, label_value
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
          failed = builder.icmp :ne, input_char, LLVM::Int8.from_i(char.ord), "matching"
          builder.add_failure_reason failed, start_input, ParsingError.new([string])
          next_char_block = builder.create_block "string_terminal_next_char"
          builder.cond failed, failed_block, next_char_block
          
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
          selection.build builder, start_input, input_char, (is_inverted ? failed_block : successful_block), next_selection_block
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
      
      def build(builder, start_input, input_char, successful_block, failed_block)
        failed = builder.icmp :ne, input_char, LLVM::Int8.from_i(character.ord), "matching"
        builder.add_failure_reason failed, start_input, ParsingError.new([character])
        builder.cond failed, failed_block, successful_block
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
      def build(builder, start_input, input_char, successful_block, failed_block)
        error = ParsingError.new(["#{begin_char.character}-#{end_char.character}"])
        begin_char_successful = builder.create_block "character_class_range_begin_char_successful"
        failed = builder.icmp :ult, input_char, LLVM::Int8.from_i(begin_char.character.ord), "begin_matching"
        builder.add_failure_reason failed, start_input, error
        builder.cond failed, failed_block, begin_char_successful
        builder.position_at_end begin_char_successful
        failed = builder.icmp :ugt, input_char, LLVM::Int8.from_i(end_char.character.ord), "end_matching"
        builder.add_failure_reason failed, start_input, error
        builder.cond failed, failed_block, successful_block
      end
    end
    
    class RuleNameLabel < Label
      def label_name
        expression.name.text_value.to_sym
      end
    end
    
    class RuleName < ParsingExpression
      def referenced
        @referenced ||= parser[name.text_value.to_sym]
      end
      
      def referenced_label_type
        (@referenced_label_type ||= RecursionGuard.new(HashLabelValueType.new({})) {
          referenced.rule_label_type
        }).value
      end
      
      def label_types
        referenced_label_type.types
      end
      
      def build(builder, start_input, failed_block)
        label_data_ptr = builder.alloca referenced_label_type.llvm_type, "label_data_ptr"
        rule_end_input = builder.call_rule referenced, start_input, label_data_ptr, "rule_end_input"
        
        rule_successful = builder.icmp :ne, rule_end_input, LLVM_STRING.null_pointer, "rule_successful"
        successful_block = builder.create_block "rule_call_successful"
        builder.cond rule_successful, successful_block, failed_block
        
        builder.position_at_end successful_block
        label_data = builder.load label_data_ptr, "label_data"
        result = Result.new rule_end_input
        result.labels = referenced_label_type.read_value builder, label_data
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
    
    class ObjectCreator < Label
      def label_type
        @object_creator_label_type ||= ObjectCreatorLabelType.new class_name.text_value.split("::").map(&:to_sym), super
      end
      
      def label_name
        DelegateLabelValueType::SYMBOL
      end
    end
  end
end