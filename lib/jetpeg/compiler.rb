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
    
    @@metagrammar_parser = nil
    
    def self.metagrammar_parser
      if @@metagrammar_parser.nil?
        File.open(File.join(File.dirname(__FILE__), "compiler/metagrammar.data"), "rb") do |io|
          metagrammar_data = JetPEG.realize_data(Marshal.load(io.read), self)
          @@metagrammar_parser = load_parser metagrammar_data
          @@metagrammar_parser.root_rules = [:choice, :grammar]
        end
      end
      @@metagrammar_parser
    end

    def self.parse(code, root)
      metagrammar_parser[root].match(code)
    end
    
    def self.compile_rule(code)
      expression = JetPEG.realize_data parse(code, :choice), self
      expression.name = :rule
      Parser.new({ "rule" => expression })
      expression
    end
    
    def self.compile_grammar(code)
      data = JetPEG.realize_data parse(code, :grammar), self
      load_parser data
    end
    
    def self.load_parser(data)
      rules = data[:rules].each_with_object({}) do |element, h|
        expression = element[:expression]
        expression.name = element[:rule_name].name
        h[expression.name] = expression
      end
      Parser.new rules
    end
    
    def self.translate_escaped_character(char)
      case char
      when "r" then "\r"
      when "n" then "\n"
      when "t" then "\t"
      else char
      end
    end
    
    class ParsingExpression
      attr_accessor :parent, :name
      
      def initialize
        @bare_rule_function = nil
        @traced_rule_function = nil
        @parse_function = nil
        @execution_engine = nil
        @parser = nil
      end
      
      def parser
        @parent.parser
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
      attr_reader :label_name
      
      def initialize(data)
        super()
        @label_name = data[:name] && data[:name].to_sym
        @expression = data[:expression]
        @expression.parent = self
      end
      
      def label_type
        (@label_type ||= RecursionGuard.new(PointerLabelValueType.new(@expression)) {
          LabelValueType.for_types(@expression.label_types)
        }).value
      end
      
      def label_types
        label_name ? { label_name => label_type } : {}
      end
      
      def build(builder, start_input, failed_block)
        result = @expression.build builder, start_input, failed_block
        value = label_type.create_value builder, result.labels, start_input, result.input
        result.labels = { label_name => value }
        result
      end
    end
    
    class Sequence < ParsingExpression
      def initialize(data)
        super()
        @children = data[:children]
        @children.each { |child| child.parent = self }
      end

      def label_types
        @label_types ||= @children.map(&:label_types).each_with_object({}) { |types, total|
          total.merge!(types) { |key, oldval, newval|
            raise CompilationError.new("Duplicate label.")
          }
        }
      end
      
      def build(builder, start_input, failed_block)
        @children.inject(Result.new(start_input)) do |result, child|
          result.merge! child.build(builder, result.input, failed_block)
        end
      end
    end
    
    class Choice < ParsingExpression
      def initialize(data)
        super()
        @children = [data[:head]] + data[:tail]
        @children.each { |child| child.parent = self }
      end
      
      def label_types
        @label_types ||= begin
          child_types = @children.map(&:label_types)
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
        child_blocks = @children.map { builder.create_block "choice_child" }
        result = BranchingResult.new builder, label_types
        builder.br child_blocks.first
        
        @children.each_with_index do |child, index|
          builder.position_at_end child_blocks[index]
          result << child.build(builder, start_input, child_blocks[index + 1] || failed_block)
          builder.br successful_block
        end
        
        builder.position_at_end successful_block
        result.generate
      end
    end
    
    class Optional < ParsingExpression
      def initialize(data)
        super()
        @expression = data[:expression]
        @expression.parent = self
      end

      def label_types
        @expression.label_types
      end
      
      def build(builder, start_input, failed_block)
        exit_block = builder.create_block "optional_exit"
        result = BranchingResult.new builder, label_types
        
        optional_failed_block = builder.create_block "optional_failed"
        result << @expression.build(builder, start_input, optional_failed_block)
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
          types = @expression.label_types
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
        
        next_result = @expression.build builder, input, exit_block
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
        result = @expression.build builder, start_input, failed_block
        label_value = label_type.create_entry(builder, result.labels, label_type.llvm_type.null) if label_type
        super builder, result.input, failed_block, label_value
      end
    end
    
    class PositiveLookahead < ParsingExpression
      def initialize(data)
        super()
        @expression = data[:expression]
        @expression.parent = self
      end

      def build(builder, start_input, failed_block)
        @expression.build builder, start_input, failed_block
        Result.new start_input
      end
    end
    
    class NegativeLookahead < ParsingExpression
      def initialize(data)
        super()
        @expression = data[:expression]
        @expression.parent = self
      end

      def build(builder, start_input, failed_block)
        lookahead_failed_block = builder.create_block "lookahead_failed"

        @expression.build builder, start_input, lookahead_failed_block
        builder.br failed_block
        
        builder.position_at_end lookahead_failed_block
        Result.new start_input
      end
    end
            
    class AnyCharacterTerminal < ParsingExpression
      def initialize(data)
      end

      def build(builder, start_input, failed_block)
        end_input = builder.gep start_input, LLVM::Int(1), "new_input"
        Result.new end_input
      end
    end
    
    class StringTerminal < ParsingExpression
      def initialize(data)
        super()
        @string = data[:string].gsub(/\\./) { |str| Compiler.translate_escaped_character str[1] }
      end
      
      def build(builder, start_input, failed_block)
        end_input = @string.chars.inject(start_input) do |input, char|
          input_char = builder.load input, "char"
          failed = builder.icmp :ne, input_char, LLVM::Int8.from_i(char.ord), "matching"
          builder.add_failure_reason failed, start_input, ParsingError.new([@string])
          next_char_block = builder.create_block "string_terminal_next_char"
          builder.cond failed, failed_block, next_char_block
          
          builder.position_at_end next_char_block
          builder.gep input, LLVM::Int(1), "new_input"
        end
        Result.new end_input
      end
    end
    
    class CharacterClassTerminal < ParsingExpression
      def initialize(data)
        super()
        @selections = data[:selections]
        @inverted = !data[:inverted].empty?
      end

      def build(builder, start_input, failed_block)
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
    end
    
    class CharacterClassSingleCharacter
      attr_reader :character
      
      def initialize(data)
        @character = data[:char_element].to_s
      end
      
      def build(builder, start_input, input_char, successful_block, failed_block)
        failed = builder.icmp :ne, input_char, LLVM::Int8.from_i(character.ord), "matching"
        builder.add_failure_reason failed, start_input, ParsingError.new([character])
        builder.cond failed, failed_block, successful_block
      end
    end
    
    class CharacterClassEscapedCharacter < CharacterClassSingleCharacter
      def initialize(data)
        super
        @character = Compiler.translate_escaped_character data[:char_element].to_s
      end
    end
    
    class CharacterClassRange
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
    end
    
    class RuleNameLabel < Label
      def label_name
        @expression.name
      end
    end
    
    class RuleName < ParsingExpression
      def initialize(data)
        super()
        @name = data[:name].to_sym
      end

      def referenced
        @referenced ||= parser[@name]
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
      def initialize(data)
        super()
        @expression = data[:expression]
        @expression.parent = self
      end

      def label_types
        @expression.label_types
      end
      
      def build(builder, start_input, failed_block)
        @expression.build builder, start_input, failed_block
      end
    end
    
    class ObjectCreator < Label
      def initialize(data)
        super
        @class_name = data[:class_name].split("::").map(&:to_sym)
      end

      def label_type
        @object_creator_label_type ||= ObjectCreatorLabelType.new @class_name, super
      end
      
      def label_name
        DelegateLabelValueType::SYMBOL
      end
    end
    
    class ValueCreator < Label
      def initialize(data)
        super
        @code = data[:code].to_s
      end

      def label_type
        @value_creator_label_type ||= ValueCreatorLabelType.new @code, super
      end
      
      def label_name
        DelegateLabelValueType::SYMBOL
      end
    end
  end
end