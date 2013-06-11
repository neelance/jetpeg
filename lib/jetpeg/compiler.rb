verbose = $VERBOSE
$VERBOSE = false
require 'llvm/core'
$VERBOSE = verbose

LLVM_STRING = LLVM::Pointer(LLVM::Int8)

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
      attr_accessor :parser, :function, :traced, :direct_left_recursion_occurred, :left_recursion_previous_end_input, :rule_start_input, :output_functions, :trace_failure_callback
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
      expression = metagrammar_parser.parse_rule :parsing_rule, code
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
  end
end

require "jetpeg/parser"

require "jetpeg/compiler/parsing_expression"
require "jetpeg/compiler/terminals"
require "jetpeg/compiler/composites"
require "jetpeg/compiler/labels"
require "jetpeg/compiler/datas"
require "jetpeg/compiler/functions"
