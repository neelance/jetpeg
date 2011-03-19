require "treetop"
require "jetpeg/compiler/metagrammar"

class String
  def append_code(str)
    insert(index(" #") || -1, str)
  end
end

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
      
      def new_position
        @pos_var_counter += 1
        Position.new("pos#{@pos_var_counter}", 0)
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
          methods = []
          @named_expressions.each do |name, expr|
            methods << expr.create_method(output) if expr.has_own_method?
          end
          
          output.puts "def parse(input)"
          output.indent do
            output.puts "#{root_rule.name}(input, 0) == input.size"
          end
          output.puts "end"
          output.puts ""
          
          methods.each do |code|
            write_code output, code
            output.puts ""
          end
        end
        
        output.puts "end"
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
      
      def create_method(output)
        pos_var = output.new_position
        matcher = create_matcher output, pos_var
        code = matcher.code
        code.last.append_code " && #{matcher.exit_pos}"
        ["def #{name}(input, #{pos_var})", code, "end"]
      end
    end
    
    class ParenthesizedExpression < ParsingExpression
      def children
        [inner_expression]
      end
      
      def fixed_length
        inner_expression.fixed_length
      end
      
      def first_character_class
        inner_expression.first_character_class
      end
      
      def create_matcher(output, entry_pos)
        inner_expression.create_matcher output, entry_pos
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
      
      def first_character_class
        children.first.first_character_class
      end
      
      def create_matcher(output, entry_pos)
        code = []
        pos = entry_pos
        children.each_index do |i|
          matcher = children[i].create_matcher output, pos
          pos = matcher.exit_pos
          code.concat matcher.code
          code.last.append_code " &&" if i < children.size - 1
        end
        Matcher.new ["( # sequence", code, ")"], pos
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
      
      def first_character_class
        @first_character_class ||= begin
          classes = @children.map { |child| child.first_character_class }
          classes.all? ? classes.join : nil
        end
      end
      
      def create_matcher(output, entry_pos)
        if fixed_length
          code = []
          children.each_index do |i|
            matcher = children[i].create_matcher output, entry_pos
            code.concat matcher.code
            code.last.append_code " ||" if i < children.size - 1
          end
          Matcher.new ["( # choice", code, ")"], entry_pos + fixed_length
        else
          code = []
          children.each_index do |i|
            matcher = children[i].create_matcher output, entry_pos
            child_code = matcher.code
            child_code.last.append_code " &&"
            child_code << matcher.exit_pos.to_s
            code.push "(", child_code, ")"
            code.last.append_code " ||" if i < children.size - 1
          end
          pos_var = output.new_position
          Matcher.new ["(#{pos_var} = ( # choice", code, "))"], pos_var
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
      
      def create_matcher(output, entry_pos)
        code = []
        pos_var = output.new_position
        code << "#{pos_var} = #{entry_pos}"
        
        matcher = expression.create_matcher output, pos_var
        
        exit_pos_assignment = if matcher.exit_pos.variable == pos_var.variable
          "#{pos_var} += #{matcher.exit_pos.offset}"
        else
          "#{pos_var} = #{matcher.exit_pos}"
        end
        
        first_character_guard = if expression.first_character_class && expression.first_character_class.size < 10
          "input[#{pos_var}, 1] =~ /[#{expression.first_character_class}]/ && "
        else
          ""
        end
        
        code.push "#{first_character_guard}while", ["(", matcher.code, ")", exit_pos_assignment], "end"
        
        code << success_expression(entry_pos, pos_var)
        Matcher.new ["begin", code , "end"], pos_var
      end
    end
    
    class ZeroOrMore < Repetition
      def success_expression(old_pos, new_pos)
        "true"
      end
      
      def first_character_class
        nil
      end
    end
    
    class OneOrMore < Repetition
      def success_expression(old_pos, new_pos)
        "#{new_pos} != #{old_pos}"
      end
      
      def first_character_class
        expression.first_character_class
      end
    end
    
    class Lookahead < ParsingExpression
      def children
        [expression]
      end
      
      def fixed_length
        0
      end
      
      def first_character_class
        nil
      end
    end
    
    class PositiveLookahead < Lookahead
      def create_matcher(output, entry_pos)
        matcher = expression.create_matcher output, entry_pos
        Matcher.new matcher.code, entry_pos
      end
    end
    
    class NegativeLookahead < Lookahead
      def create_matcher(output, entry_pos)
        matcher = expression.create_matcher output, entry_pos
        code = matcher.code
        code.first.insert 0, "!"
        Matcher.new code, entry_pos
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
      
      def first_character_class
        nil
      end
      
      def create_matcher(output, entry_pos)
        Matcher.new ["true"], entry_pos + 1
      end
    end
    
    class StringTerminal < Terminal
      def string
        @string ||= eval text_value
      end
      
      def fixed_length
        string.size
      end
      
      def first_character_class
        case string[0, 1]
        when '-' then '\-'
        when '\\' then '\\\\'
        else string[0, 1]
        end
      end
      
      def create_matcher(output, entry_pos)
        Matcher.new ["(input[#{entry_pos}, #{string.size}] == #{string.inspect})"], entry_pos + string.size
      end
    end
    
    class CharacterClassTerminal < Terminal
      def fixed_length
        1
      end
      
      def first_character_class
        characters.text_value[0, 1] != '^' ? characters.text_value : nil
      end
      
      def create_matcher(output, entry_pos)
        Matcher.new ["(input[#{entry_pos}, 1] =~ /[#{characters.text_value}]/)"], entry_pos + 1
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
      
      def first_character_class
        if referenced_expression.recursive
          nil
        else
          referenced_expression.first_character_class
        end
      end
      
      def create_matcher(output, entry_pos)
        if referenced_expression.has_own_method?
          pos_var = output.new_position
          Matcher.new ["(#{pos_var} = #{name.text_value}(input, #{entry_pos}))"], pos_var
        else
          referenced_expression.create_matcher output, entry_pos
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