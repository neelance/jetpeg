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
    self.each_key do |key|
      h[key] = yield key, self[key]
    end
    h
  end
  
  def map_hash!
    self.each_key do |key|
      self[key] = yield key, self[key]
    end
  end
end

class Module
  def to_proc
    lambda { |obj| obj.is_a? self }
  end
end

module JetPEG
  class CompilationError < RuntimeError
    attr_reader :rule
    
    def initialize(msg, rule = nil)
      @msg = msg
      @rule = rule
    end
    
    def to_s
      "In rule \"#{@rule ? @rule.rule_name : '<unknown>'}\": #{@msg}"
    end
  end
  
  module Compiler
    class Builder < LLVM::Builder
      class LazyBlock
        def initialize(function, name)
          @function = function
          @name = name
        end
        
        def to_ptr
          @block ||= @function.basic_blocks.append @name
          @block.to_ptr
        end
      end
      
      attr_accessor :traced, :add_failure_callback
      
      def init(mod, track_malloc)
        @mod = mod
        if track_malloc
          @malloc_counter = @mod.globals.add LLVM::Int64, :malloc_counter
          @malloc_counter.initializer = LLVM::Int64.from_i(0)
          @free_counter = @mod.globals.add LLVM::Int64, :free_counter
          @free_counter.initializer = LLVM::Int64.from_i(0)
        else
          @malloc_counter = nil
          @free_counter = nil
        end
      end
      
      def create_block(name)
        LazyBlock.new self.insert_block.parent, name
      end
      
      def create_struct(llvm_type)
        llvm_type.null
      end
      
      def extract_values(aggregate, count)
        count.times.map { |i| extract_value aggregate, i }
      end
      
      def insert_values(aggregate, values, indices)
        values.zip(indices).inject(aggregate) { |a, (value, i)| insert_value a, value, i }
      end
      
      def malloc(type, name = "")
        if @malloc_counter
          old_value = self.load @malloc_counter
          new_value = self.add old_value, LLVM::Int64.from_i(1)
          self.store new_value, @malloc_counter
        end
        super
      end
      
      def free(pointer)
        if @free_counter
          old_value = self.load @free_counter
          new_value = self.add old_value, LLVM::Int64.from_i(1)
          self.store new_value, @free_counter
        end
        super
      end
      
      def add_failure_reason(failed_block, position, reason, is_expectation = true)
        return failed_block if not @traced
        
        initial_block = self.insert_block
        failure_reason_block = self.create_block "add_failure_reason"
        self.position_at_end failure_reason_block
        self.call @add_failure_callback, position, self.global_string_pointer(reason.inspect[1..-2]), is_expectation ? LLVM::TRUE : LLVM::FALSE
        self.br failed_block
        self.position_at_end initial_block
        failure_reason_block
      end
      
      def build_use_counter_increment(type, value)
        llvm_type = type.is_a?(ValueType) ? type.llvm_type : type
        case llvm_type.kind
        when :struct
          llvm_type.element_types.each_with_index do |element_type, i|
            next if not [:struct, :pointer].include? element_type.kind
            element = self.extract_value value, i
            build_use_counter_increment element_type, element
          end
          
        when :pointer
          return if llvm_type.element_type.kind != :struct or llvm_type.element_type.element_types.empty?
          
          increment_counter_block = self.create_block "increment_counter"
          continue_block = self.create_block "continue"
          
          not_null = self.icmp :ne, value, llvm_type.null, "not_null"
          self.cond not_null, increment_counter_block, continue_block
          
          self.position_at_end increment_counter_block
          additional_use_counter = self.struct_gep value, 1, "additional_use_counter"
          old_counter_value = self.load additional_use_counter
          new_counter_value = self.add old_counter_value, LLVM::Int64.from_i(1)
          self.store new_counter_value, additional_use_counter
          self.br continue_block

          self.position_at_end continue_block
        end
      end
    end
    
    class Recursion < RuntimeError
      attr_reader :expression
      
      def initialize(expression)
        @expression = expression
      end
    end
    
    Result = Struct.new :input, :return_value
    
    @@metagrammar_parser = nil
    
    def self.metagrammar_parser
      if @@metagrammar_parser.nil?
        begin
          mod = LLVM::Module.parse_bitcode File.join(File.dirname(__FILE__), "compiler/metagrammar.jetpeg.bc")
          @@metagrammar_parser = Parser.new mod
        rescue Exception => e
          $stderr.puts "Could not load metagrammar:", e, e.backtrace
          exit
        end
      end
      @@metagrammar_parser
    end

    def self.compile_rule(code, filename = "grammar")
      expression = metagrammar_parser.parse_rule :rule_expression, code, output: :realized, class_scope: self, raise_on_failure: true
      expression.rule_name = :rule
      JitParser.new({ "rule" => expression }, filename)
    rescue ParsingError => e
      raise CompilationError, "Syntax error in grammar: #{e}"
    end
    
    def self.compile_grammar(code, filename = "grammar")
      data = metagrammar_parser.parse_rule :grammar, code, output: :realized, class_scope: self, raise_on_failure: true
      parser = load_parser data, filename
      parser
    rescue ParsingError => e
      raise CompilationError, "Syntax error in grammar: #{e}"
    end
    
    def self.load_parser(data, filename)
      rules = data[:rules].each_with_object({}) do |element, h|
        expression = element[:expression]
        expression.rule_name = element[:rule_name].to_sym
        expression.parameters = element[:parameters] ? ([element[:parameters][:head]] + element[:parameters][:tail]).map{ |p| Parameter.new p.name } : []
        h[expression.rule_name] = expression
      end
      JitParser.new rules, filename
    end
    
    def self.translate_escaped_character(char)
      case char
      when "r" then "\r"
      when "n" then "\n"
      when "t" then "\t"
      when "0" then "\0"
      else char
      end
    end
  end
end

require "jetpeg/parser"
require "jetpeg/values"

require "jetpeg/compiler/tools"
require "jetpeg/compiler/parsing_expression"
require "jetpeg/compiler/terminals"
require "jetpeg/compiler/composites"
require "jetpeg/compiler/labels"
require "jetpeg/compiler/functions"

require "jetpeg/compiler/optimizations/ruby_side_struct"
require "jetpeg/compiler/optimizations/leftmost_primary_rewrite"
