require "treetop"
require "jetpeg/compiler/metagrammar"

module JetPEG
  module Compiler
    def self.compile(code)
      metagrammar_parser = MetagrammarParser.new
      grammar = metagrammar_parser.parse code
      
      if grammar.nil?
        puts metagrammar_parser.failure_reason
        exit
      end
      
      grammar.construct
      grammar.compile
    end
    
    class IndentingOutput
      attr_reader :content
      
      def initialize
        @content = ""
        @indention = 0
        @pos_var_counter = 0
      end
      
      def inc_indention
        @indention += 1
      end
      
      def dec_indention
        @indention -= 1
      end
      
      def indent
        @indention += 1
        yield
        @indention -= 1
      end
      
      def puts(line)
        @content += "#{'  ' * @indention}#{line}\n" 
      end
      
      def new_pos_var
        @pos_var_counter += 1
        "pos#{@pos_var_counter}"
      end
    end
    
    class Grammar < Treetop::Runtime::SyntaxNode
      attr_accessor :name
      
      def initialize(*args)
        super
        @surrounding_modules = []
        @named_expressions = {}
      end
      
      def add_surrounding_module(name)
        @surrounding_modules << name
      end
      
      def add_named_expression(expr)
        @named_expressions[expr.name] = expr
      end
      
      def find_expression(name)
        @named_expressions[name]
      end
      
      def compile(root_rule_name = nil)
        root_rule = root_rule_name ? @named_expressions[root_rule_name] : @named_expressions.values.first
        root_rule.own_method_requested = true
        root_rule.mark_recursions []
        
        output = IndentingOutput.new
        output.puts "class #{@name}Parser"
        
        output.indent do
          output.puts "def parse(input)"
          output.indent do
            output.puts "@input = input"
            output.puts "#{root_rule.name}(0) == @input.size"
          end
          output.puts "end"
          output.puts ""

          @named_expressions.each do |name, expr|
            expr.write_method output if expr.has_own_method?
          end
        end
        
        output.puts "end"
      end
    end

    class ParsingExpression < Treetop::Runtime::SyntaxNode
      attr_accessor :name, :own_method_requested, :recursive
      
      def initialize(*args)
        super
        @own_method_requested = false
        @recursive = false
      end
      
      def grammar
        element = parent
        element = element.parent while not element.is_a?(Grammar)
        element
      end
      
      def mark_recursions(inside_expressions)
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
        @own_method_requested || @recursive
      end
      
      def write_method(output)
        pos_var = output.new_pos_var
        output.puts "def #{name}(#{pos_var})"
        output.indent do
          matcher = create_matcher output, Position.new(pos_var, 0)
          code = matcher.code
          code.last << " && #{matcher.exit_pos}"
          write_code output, code
        end
        output.puts "end"
        output.puts ""
      end
      
      def write_code(output, array)
        array.each do |part|
          case part
          when String
            output.puts part
          when Array
            output.indent do
              write_code output, part
            end
          else
            raise ArgumenrError
          end
        end
      end
    end
    
    class ParenthesizedExpression < ParsingExpression
      def children
        [inner_expression]
      end
      
      def fixed_length
        inner_expression.fixed_length
      end
      
      def create_matcher(output, pos)
        inner_expression.create_matcher output, pos
      end
    end
    
    class Sequence < ParsingExpression
      def children
        @children ||= [head] + tail.elements
      end
      
      def fixed_length
        @fixed_length ||= begin
          length = 0
          children.each do |exp|
            l = exp.fixed_length
            return nil if l.nil?
            length += l
          end
          length
        end
      end
      
      def create_matcher(output, pos)
        code = []
        children.each_index do |i|
          matcher = children[i].create_matcher output, pos
          pos = matcher.exit_pos
          code.concat matcher.code
          code.last << " &&" if i < children.size - 1
        end
        Matcher.new ["(", code, ")"], pos
      end
    end
    
    class Choice < ParsingExpression
      def children
        @children ||= [head] + tail.elements.map { |e| e.alternative }
      end
      
      def fixed_length
        @fixed_length ||= begin
          length = nil
          children.each do |exp|
            l = exp.fixed_length
            return nil if l.nil?
            if length.nil?
              length = l
            else
              return nil if length != l
            end
          end
          length
        end
      end
      
      def create_matcher(output, pos)
        if fixed_length
          code = []
          children.each_index do |i|
            matcher = children[i].create_matcher output, pos
            code.concat matcher.code
            code.last << " ||" if i < children.size - 1
          end
          Matcher.new ["(", code, ")"], pos + fixed_length
        else
          code = []
          pos_var = output.new_pos_var
          children.each_index do |i|
            matcher = children[i].create_matcher output, pos
            child_code = matcher.code
            child_code.last << " &&"
            child_code << "#{pos_var} = #{matcher.exit_pos}"
            code.push "(", child_code, ")"
            code.last << " ||" if i < children.size - 1
          end
          Matcher.new ["(", code, ")"], Position.new(pos_var, 0)
        end
      end
    end
    
    class Repetition < ParsingExpression
      def children
        [expression]
      end
      
      def fixed_length
        nil
      end
      
      def create_matcher(output, pos)
        code = []
        pos_var = output.new_pos_var
        code << "#{pos_var} = #{pos}"
        
        matcher = expression.create_matcher output, Position.new(pos_var, 0)
        
        exit_pos_assignment = if matcher.exit_pos.variable == pos_var
          "#{pos_var} += #{matcher.exit_pos.offset}"
        else
          "#{pos_var} = #{matcher.exit_pos}"
        end
          
        code.push "while", ["(", matcher.code, ")", exit_pos_assignment], "end"
        
        code << success_expression(pos, pos_var)
        Matcher.new ["begin", code , "end"], Position.new(pos_var, 0)
      end
    end
    
    class ZeroOrMore < Repetition
      def success_expression(old_pos, new_pos)
        "true"
      end
    end
    
    class OneOrMore < Repetition
      def success_expression(old_pos, new_pos)
        "#{new_pos} != #{old_pos}"
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
      def create_matcher(output, pos)
        matcher = expression.create_matcher output, pos
        Matcher.new matcher.code, pos
      end
    end
    
    class NegativeLookahead < Lookahead
      def create_matcher(output, pos)
        matcher = expression.create_matcher output, pos
        code = matcher.code
        code.first.insert 0, "!"
        Matcher.new code, pos
      end
    end
    
    class Terminal < ParsingExpression
      def children
        []
      end
    end
    
    class StringTerminal < Terminal
      def string
        @string ||= eval text_value
      end
      
      def fixed_length
        string.size
      end
      
      def create_matcher(output, pos)
        Matcher.new ["(@input[#{pos}, #{string.size}] == #{string.inspect})"], pos + string.size
      end
    end
    
    class AnyCharacterTerminal < Terminal
      def fixed_length
        1
      end
      
      def create_matcher(output, pos)
        Matcher.new ["true"], pos + 1
      end
    end
    
    class CharacterClassTerminal < Terminal
      def fixed_length
        1
      end
      
      def create_matcher(output, pos)
        Matcher.new ["(@input[#{pos}, 1] =~ /[#{characters.text_value}]/)"], pos + 1
      end
    end
    
    class RuleName < ParsingExpression
      def referenced_expression
        @referenced_expression ||= grammar.find_expression(name.text_value)
      end
      
      def children
        [referenced_expression]
      end
      
      def fixed_length
        if referenced_expression.recursive
          nil
        else
          referenced_expression.fixed_length
        end
      end
      
      def create_matcher(output, pos)
        if referenced_expression.recursive
          pos_var = output.new_pos_var
          Matcher.new ["(#{pos_var} = #{name.text_value}(#{pos}))"], Position.new(pos_var, 0)
        else
          referenced_expression.create_matcher output, pos
        end
      end
    end
    
    class Position
      attr_reader :variable, :offset
      
      def initialize(variable, offset)
        @variable = variable
        @offset = offset
      end
      
      def +(length)
        Position.new @variable, @offset + length
      end
      
      def to_s
        if @offset == 0
          @variable
        else
          "#{@variable} + #{@offset}"
        end
      end
    end
    
    class Matcher
      attr_reader :code, :exit_pos
      
      def initialize(code, exit_pos)
        @code = code
        @exit_pos = exit_pos
      end
    end
  end
end