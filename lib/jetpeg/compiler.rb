verbose = $VERBOSE
$VERBOSE = false
require 'llvm/core'
$VERBOSE = verbose

LLVM_STRING = LLVM::Pointer(LLVM::Int8)

class FFI::Struct
  def inspect
    "{ #{members.map{ |name| "#{name}=#{self[name].inspect}" }.join ", "} }"
  end
end

class Hash
  def map_hash
    h = {}
    self.keys.each do |key|
      h[key] = yield key, self[key]
    end
    h
  end
  
  def map_hash!
    self.keys.each do |key|
      self[key] = yield key, self[key]
    end
  end
end

require "jetpeg/parser"
require "jetpeg/label_value"
require "jetpeg/compiler/tools"

module JetPEG
  class CompilationError < RuntimeError
    attr_accessor :rule
    
    def initialize(msg, rule = nil)
      @msg = msg
      @rule = rule
    end
    
    def to_s
      "In rule \"#{@rule ? @rule.name : '<unknown>'}\": #{@msg}"
    end
  end
  
  module Compiler
    class Builder < LLVM::Builder
      attr_writer :parser, :traced
      
      def create_block(name)
        LLVM::BasicBlock.create self.insert_block.parent, name
      end
      
      def malloc(size)
        self.call @parser.malloc, size
      end
      
      def call_rule(rule, *args)
        self.call rule.rule_function(@traced), *args
      end
      
      def add_failure_reason(failed, position, reason)
        return if not @traced
        @parser.possible_failure_reasons << reason
        callback = self.load @parser.llvm_add_failure_reason_callback, "callback"
        self.call callback, failed, position, LLVM::Int(@parser.possible_failure_reasons.size - 1)
      end
    end
    
    class Recursion < RuntimeError
    end
    
    @@metagrammar_parser = nil
    
    def self.metagrammar_parser
      if @@metagrammar_parser.nil?
        begin
          File.open(File.join(File.dirname(__FILE__), "compiler/metagrammar.data"), "rb") do |io|
            metagrammar_data = JetPEG.realize_data(Marshal.load(io.read), self)
            @@metagrammar_parser = load_parser metagrammar_data
            @@metagrammar_parser.verify!
            @@metagrammar_parser.root_rules = [:choice, :grammar]
            @@metagrammar_parser.build
          end
        rescue Exception => e
          $stderr.puts "Could not load metagrammar:", e, e.backtrace
          exit
        end
      end
      @@metagrammar_parser
    end

    def self.compile_rule(code, filename = nil)
      expression = metagrammar_parser[:rule_expression].match code, :output => :realized, :class_scope => self
      expression.name = :rule
      parser = Parser.new({ "rule" => expression })
      parser.filename = filename if filename
      parser.verify!
      expression
    end
    
    def self.compile_grammar(code, filename = nil)
      data = metagrammar_parser[:grammar].match code, :output => :realized, :class_scope => self
      parser = load_parser data
      parser.filename = filename if filename
      parser.verify!
      parser
    end
    
    def self.load_parser(data)
      rules = data[:rules].each_with_object({}) do |element, h|
        expression = element[:expression]
        expression.name = element[:rule_name].referenced_name
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
      attr_reader :recursive_labels
      
      def initialize(data)
        @name = nil
        @rule_label_type = nil
        @bare_rule_function = nil
        @traced_rule_function = nil
        @recursive_labels = []
        
        if data.is_a?(Hash)
          @children = data.values.flatten.select { |value| value.is_a? ParsingExpression }
          @children.each { |child| child.parent = self }
        else
          @children = []
        end
      end
      
      def parser
        @parent.parser
      end
      
      def metagrammar?
        parser == JetPEG::Compiler.metagrammar_parser
      end
      
      def rule
        @name ? self : parent.rule
      end
      
      def create_label_types
        {}
      end
      
      def rule_label_type
        raise Recursion if @rule_label_type == :recursion
        if @rule_label_type.nil?
          begin
            @rule_label_type = :recursion
            @rule_label_type = HashLabelValueType.new create_label_types
          rescue Recursion
            @rule_label_type = HashLabelValueType.new({})
            raise CompilationError.new("Unlabeled recursion mixed with other labels.") if not create_label_types.empty?
          end
        end
        @rule_label_type
      rescue CompilationError => e
        e.rule ||= self
        raise e
      end
      
      def realize_label_types
        @recursive_labels.map(&:label_type).each(&:create_target_type)
      end
      
      def build_allocas(builder)
        @children.each { |child| child.build_allocas builder }
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
          
          builder = Builder.new
          builder.parser = parser
          builder.traced = traced
          
          entry = function.basic_blocks.append "entry"
          builder.position_at_end entry
          build_allocas builder
  
          failed_block = builder.create_block "failed"
          end_result = build builder, input, failed_block
          
          data = rule_label_type.create_value builder, end_result.labels
          builder.store data, data_ptr unless data.value.null?
          
          builder.ret end_result.input
  
          builder.position_at_end failed_block
          builder.ret LLVM_STRING.null_pointer
        end
      rescue CompilationError => e
        e.rule ||= self
        raise e
      end
      
      def match(input, options = {})
        parser.match_rule self, input, options
      end
    end
    
    class Label < ParsingExpression
      attr_reader :label_name
      
      def initialize(data)
        super
        @label_name = data[:name] && data[:name].to_sym
        @expression = data[:expression]
      end
      
      def label_type
        @label_type ||= begin
          types = @expression.create_label_types
          if types.empty?
            InputRangeLabelValueType::INSTANCE
          else
            HashLabelValueType.new types
          end
        rescue Recursion
          rule.recursive_labels << self
          PointerLabelValueType.new @expression
        end
      end
      
      def create_label_types
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
        super
        @children = data[:children]
      end

      def create_label_types
        @children.each_with_object({}) { |child, total|
          total.merge!(child.create_label_types) { |key, oldval, newval|
            raise CompilationError.new("Duplicate label (#{key}).")
          }
          raise CompilationError.new("Label @ mixed with other labels (#{total.keys.join(', ')}).") if total.has_key?(AT_SYMBOL) and total.size > 1
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
        super
        @children = [data[:head]] + data[:tail]
      end
      
      def create_label_types
        @slots = {}
        @label_types = {}
        child_types = @children.map { |child| child.create_label_types }
        child_types.map(&:keys).flatten.uniq.each do |key|
          types_for_label = child_types.map { |t| t[key] }
          slot = LabelSlot.new key, types_for_label
          @slots[key] = slot
          @label_types[key] = slot.slot_type
        end
        
        @label_types
      end
      
      def build(builder, start_input, failed_block)
        successful_block = builder.create_block "choice_successful"
        child_blocks = @children.map { builder.create_block "choice_child" }
        result = BranchingResult.new builder, @label_types
        builder.br child_blocks.first
        
        @children.each_with_index do |child, index|
          builder.position_at_end child_blocks[index]
          child_result = child.build(builder, start_input, child_blocks[index + 1] || failed_block)
          child_result.labels.map_hash! { |name, value| @slots[name].slot_value builder, value }
          result << child_result
          builder.br successful_block
        end
        
        builder.position_at_end successful_block
        result.generate
      end
    end
    
    class Optional < ParsingExpression
      def initialize(data)
        super
        @expression = data[:expression]
      end

      def create_label_types
        @label_types = @expression.create_label_types
      end
      
      def build(builder, start_input, failed_block)
        exit_block = builder.create_block "optional_exit"
        result = BranchingResult.new builder, @label_types
        
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
          types = @expression.create_label_types
          !types.empty? && ArrayLabelValueType.new(super)
        end
      end
      
      def label_name
        label_type && AT_SYMBOL
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
        result.labels = { AT_SYMBOL => LabelValue.new(label_value, label_type) } if label_type
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
    
    class Until < Label
      def initialize(data)
        super
        @until_expression = data[:until_expression]
      end
      
      def label_type
        @array_label_type ||= begin
          types = @expression.create_label_types
          types.merge!(@until_expression.create_label_types) { |key, oldval, newval| raise CompilationError.new("Overlapping labels in until-expression.") }
          !types.empty? && ArrayLabelValueType.new(HashLabelValueType.new types)
        end
      end
      
      def label_name
        label_type && AT_SYMBOL
      end
      
      def build(builder, start_input, failed_block, start_label_value = nil)
        start_block = builder.insert_block
        loop1_block = builder.create_block "until_loop1"
        loop2_block = builder.create_block "until_loop2"
        exit_block = builder.create_block "until_exit"
        builder.br loop1_block
        
        builder.position_at_end loop1_block
        input = builder.phi LLVM_STRING, { start_block => start_input }, "loop_input"
        label_value = builder.phi label_type.llvm_type, { start_block => start_label_value || label_type.llvm_type.null }, "loop_label_value" if label_type
        
        until_result = @until_expression.build builder, input, loop2_block
        builder.br exit_block
        
        builder.position_at_end loop2_block
        next_result = @expression.build builder, input, failed_block
        input.add_incoming builder.insert_block => next_result.input
        label_value.add_incoming builder.insert_block => label_type.create_entry(builder, next_result.labels, label_value) if label_type
        builder.br loop1_block
        
        builder.position_at_end exit_block
        result = Result.new until_result.input
        result.labels = { AT_SYMBOL => LabelValue.new(label_type.create_entry(builder, until_result.labels, label_value), label_type) } if label_type
        result
      end
    end
    
    class PositiveLookahead < ParsingExpression
      def initialize(data)
        super
        @expression = data[:expression]
      end

      def build(builder, start_input, failed_block)
        @expression.build builder, start_input, failed_block
        Result.new start_input
      end
    end
    
    class NegativeLookahead < ParsingExpression
      def initialize(data)
        super
        @expression = data[:expression]
      end

      def build(builder, start_input, failed_block)
        lookahead_failed_block = builder.create_block "lookahead_failed"

        @expression.build builder, start_input, lookahead_failed_block
        builder.br failed_block
        
        builder.position_at_end lookahead_failed_block
        Result.new start_input
      end
    end
            
    class StringTerminal < ParsingExpression
      def initialize(data)
        super
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
        super
        @selections = data[:selections]
        @inverted = data[:inverted] && !data[:inverted].empty?
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
        @character = data[:char_element]
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
        @character = Compiler.translate_escaped_character data[:char_element]
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
    
    class AnyCharacterTerminal < CharacterClassTerminal
      SELECTIONS = [CharacterClassSingleCharacter.new({ :char_element => "\0" })]
      
      def initialize(data)
        super({})
        @selections = SELECTIONS
        @inverted = true
      end
    end
    
    class RuleNameLabel < Label
      def label_name
        @expression.referenced_name
      end
    end
    
    class RuleName < ParsingExpression
      attr_reader :referenced_name
      
      def initialize(data)
        super
        @referenced_name = data[:name].to_sym
      end
      
      def referenced
        @referenced ||= parser[@referenced_name]
      end
      
      def create_label_types
        referenced.rule_label_type.types
      end
      
      def build_allocas(builder)
        @label_data_ptr = referenced.rule_label_type.alloca builder, "#{@referenced_name}_data_ptr"
      end
      
      def build(builder, start_input, failed_block)
        rule_end_input = builder.call_rule referenced, start_input, @label_data_ptr, "rule_end_input"
        
        rule_successful = builder.icmp :ne, rule_end_input, LLVM_STRING.null_pointer, "rule_successful"
        successful_block = builder.create_block "rule_call_successful"
        builder.cond rule_successful, successful_block, failed_block
        
        builder.position_at_end successful_block
        result = Result.new rule_end_input
        unless @label_data_ptr.null?
          label_data = builder.load @label_data_ptr, "#{@referenced_name}_data"
          result.labels = referenced.rule_label_type.read_value builder, label_data
        end
        result
      end
    end
    
    class ParenthesizedExpression < ParsingExpression
      def initialize(data)
        super
        @expression = data[:expression]
      end
      
      def create_label_types
        @expression.create_label_types
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
        @object_creator_label_type ||= CreatorLabelType.new super, :$type => :object, :class_name => @class_name
      end
      
      def label_name
        AT_SYMBOL
      end
    end
    
    class ValueCreator < Label
      def initialize(data)
        super
        @code = data[:code]
        input_range = data.intermediate[:code]
        @lineno = input_range[:input][0, input_range[:position].begin].count("\n") + 1
      end

      def label_type
        @value_creator_label_type ||= CreatorLabelType.new super, :$type => :value, :code => @code, :filename => parser.filename, :lineno => @lineno
      end
      
      def label_name
        AT_SYMBOL
      end
    end
  end
end
