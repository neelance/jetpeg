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
      attr_accessor :parser, :traced, :direct_left_recursion_occurred, :left_recursion_previous_end_input, :rule_start_input, :output_functions, :trace_failure_callback
      
      def create_block(name)
        self.insert_block.parent.basic_blocks.append name
      end
      
      def trace_failure_reason(failed_block, position, reason, is_expectation = true)
        return failed_block if not @traced
        
        initial_block = self.insert_block
        failure_reason_block = self.create_block "trace_failure_reason"
        self.position_at_end failure_reason_block
        self.call output_functions[:trace_failure], position, self.global_string_pointer(reason.inspect[1..-2]), is_expectation ? LLVM::TRUE : LLVM::FALSE
        self.br failed_block
        self.position_at_end initial_block
        failure_reason_block
      end
    end
    
    @@metagrammar_parser = nil
    
    def self.metagrammar_parser
      if @@metagrammar_parser.nil?
        begin
          mod = LLVM::Module.parse_bitcode File.join(File.dirname(__FILE__), "compiler/metagrammar.jetpeg.bc")
          @@metagrammar_parser = Parser.new mod, class_scope: self, raise_on_failure: true
        rescue Exception => e
          $stderr.puts "Could not load metagrammar:", e, e.backtrace
          exit
        end
      end
      @@metagrammar_parser
    end

    def self.compile_rule(code, options = {})
      expression = metagrammar_parser.parse_rule :rule_expression, code
      expression.rule_name = :rule
      JitParser.new({ :rule => expression }, options)
    rescue ParsingError => e
      raise CompilationError, "Syntax error in grammar: #{e}"
    end
    
    def self.compile_grammar(code, options = {})
      data = metagrammar_parser.parse_rule :grammar, code
      parser = load_parser data, options
      parser
    rescue ParsingError => e
      raise CompilationError, "Syntax error in grammar: #{e}"
    end
    
    def self.load_parser(data, options)
      rules = data[:rules].each_with_object({}) do |element, h|
        expression = element[:child]
        expression.rule_name = element[:rule_name].to_sym
        expression.parameters = (element[:parameters] || []).map{ |p| Parameter.new p.data[:name] }
        h[expression.rule_name] = expression
      end
      JitParser.new rules, options
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

require "jetpeg/compiler/parsing_expression"
require "jetpeg/compiler/terminals"
require "jetpeg/compiler/composites"
require "jetpeg/compiler/labels"
require "jetpeg/compiler/datas"
require "jetpeg/compiler/functions"
