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
      expression.label_type # check label types
      expression
    end
    
    def self.compile_grammar(code)
      rules = parse(code, :grammar).rules
      mod = LLVM::Module.create "Parser"
      Grammar.new mod, rules
    end
    
    class PhiGenerator
      attr_accessor :explicit_blocks
      
      def initialize(builder)
        @builder = builder
        @values = {}
        @explicit_blocks = nil
      end
      
      def <<(value)
        @values[@builder.insert_block] = value
      end
      
      def generate(type, name = "")
        @explicit_blocks.each { |block| @values[block] ||= type.null } if @explicit_blocks
        @builder.phi type, @values, name
      end
    end
    
    class PhiGeneratorHash
      def initialize(builder, generator_class)
        @builder = builder
        @phis = Hash.new { |h, k| h[k] = generator_class.new(builder) }
        @blocks = []
      end
      
      def merge!(hash)
        @blocks << @builder.insert_block
        hash.each { |name, value| @phis[name] << value }
      end
      
      def generate
        @phis.each_with_object({}) { |(name, phi), h|
          phi.explicit_blocks = @blocks
          h[name] = phi.generate(name.to_s)
        }
      end
    end
    
    class Terminal
      attr_reader :position
      
      def initialize(input, position)
        @input = input
        @position = position
      end
      
      def to_s
        @text ||= @input[@position]
      end
      alias_method :to_str, :to_s
      
      def ==(other)
        to_s == other.to_s
      end
      
      def [](*args)
        to_s[*args]
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
      class LabelValueGenerator < PhiGenerator
        def generate(name = "")
          types = @values.values.map(&:type).uniq
          raise SyntaxError, "Incompatible label types." if types.size != 1
          LabelValue.create types.first, super(types.first.llvm_type, name)
        end
      end
      
      def initialize(builder)
        @input_phi = PhiGenerator.new builder
        @label_phis = PhiGeneratorHash.new builder, LabelValueGenerator
      end
      
      def <<(result)
        @input_phi << result.input
        @label_phis.merge! result.labels
      end
      
      def generate
        @input = @input_phi.generate LLVM_STRING, "input"
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
    
    class Dummy
      def method_missing(name, *args)
        Dummy.new
      end
      
      def null?
        false
      end
    end
    
    class LabelValue < LLVM::Value
      attr_accessor :type
      
      def self.create(type, value)
        inst = from_ptr value.to_ptr
        inst.type = type
        inst
      end
    end
    
    class LabelType
      private_class_method :new
      attr_reader :llvm_type, :ffi_type
      
      def initialize(llvm_type, ffi_type)
        @llvm_type = llvm_type
        @ffi_type = ffi_type
      end
    end
    
    class TerminalLabelValue < LabelType
      TYPE = new LLVM::Struct(LLVM_STRING, LLVM_STRING), Class.new(FFI::Struct).tap{ |s| s.layout(:begin, :pointer, :end, :pointer) }

      def self.create(builder, begin_pos, end_pos)
        pos = TYPE.llvm_type.null
        pos = builder.insert_value pos, begin_pos, 0
        pos = builder.insert_value pos, end_pos, 1
        LabelValue.create TYPE, pos
      end
      
      def read(data, input, input_address)
        if data[:begin].null?
          nil
        else
          Terminal.new input, (data[:begin].address - input_address)...(data[:end].address - input_address)
        end
      end
    end
    
    class HashLabelValue < LabelType
      def self.create(builder, labels)
        type = new(labels.each_with_object({}) { |(name, value), h| h[name] = value.type })
        data = type.llvm_type.null
        labels.each_with_index do |(name, value), index|
          data = builder.insert_value data, value, index
        end
        LabelValue.create type, data
      end
      
      def initialize(types)
        @types = types
        llvm_type = LLVM::Struct(*types.values.map(&:llvm_type))
        ffi_type = Class.new FFI::Struct
        ffi_type.layout(*types.map{ |name, type| [name, type.ffi_type] }.flatten)
        super llvm_type, ffi_type
      end
      
      def read(data, input, input_address)
        values = {}
        @types.each do |name, type|
          values[name] = type.read data[name], input, input_address
        end
        values
      end
      
      def empty?
        @types.empty?
      end

      EMPTY_TYPE = new({})
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
      
      def label_type
        @label_type ||= begin
          builder = Dummy.new
          @label_type = HashLabelValue::EMPTY_TYPE # avoid recursion
          dummy_result = build builder, nil, nil
          HashLabelValue.create(builder, dummy_result.labels).type
        end
      end
      
      def rule_function
        if @rule_function.nil?
          @mod.functions.add(@name, [LLVM_STRING, LLVM::Pointer(label_type.llvm_type)], LLVM_STRING) do |function, input, data_ptr|
            @rule_function = function
            entry = function.basic_blocks.append "entry"
            builder = LLVM::Builder.create
            builder.position_at_end entry
    
            failed_block = builder.create_block "failed"
            end_result = build builder, input, failed_block
            
            unless label_type.empty?
              data = HashLabelValue.create builder, end_result.labels
              builder.store data, data_ptr
            end
            
            builder.ret end_result.input
    
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
        data = !label_type.empty? && label_type.ffi_type.new
        input_end_ptr = execution_engine.run_function(rule_function, input_ptr, data && data.pointer).to_value_ptr
        
        if input_ptr.address + input.size == input_end_ptr.address
          label_type.read data, input, input_ptr.address
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
        children.inject(Result.new(start_input)) do |result, child|
          result.merge! child.build(builder, result.input, failed_block)
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
        result = BranchingResult.new builder
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
      def build(builder, start_input, failed_block)
        exit_block = builder.create_block "optional_exit"
        result = BranchingResult.new builder
        
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
      def build(builder, start_input, failed_block)
        referenced = grammar[name.text_value]
        rule_end_input = builder.call referenced, start_input, LLVM::Pointer(referenced.label_type.llvm_type).null_pointer
        rule_successful = builder.icmp :ne, rule_end_input, LLVM_STRING.null_pointer, "rule_successful"
        successful_block = builder.create_block "rule_call_successful"
        builder.cond rule_successful, successful_block, failed_block
        builder.position_at_end successful_block
        Result.new rule_end_input
      end
    end
    
    class ParenthesizedExpression < ParsingExpression
      def build(builder, start_input, failed_block)
        expression.build builder, start_input, failed_block
      end
    end
    
    class Label < ParsingExpression
      def build(builder, start_input, failed_block)
        result = expression.build builder, start_input, failed_block
        value = if result.labels.empty?
          TerminalLabelValue.create builder, start_input, result.input
        else
          HashLabelValue.create builder, result.labels
        end
        result.labels = { name.text_value.to_sym => value }
        result
      end
    end
  end
end