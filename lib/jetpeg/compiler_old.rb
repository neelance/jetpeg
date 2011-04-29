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
      raise metagrammar_parser.failure_reason if grammar.nil?
      
      grammar.construct
      grammar.compile
    end
    
    def self.compile_rule(code)
      metagrammar_parser = MetagrammarParser.new
      expression = metagrammar_parser.parse code, :root => :choice
      raise metagrammar_parser.failure_reason if expression.nil?
      
      context = Grammar.new
      pos_var = context.new_position
      matcher = expression.create_matcher context, pos_var
      
      matcher
    end
    
    class CompiledRule
      def initialize
    end
    
    class Grammar < Treetop::Runtime::SyntaxNode
      attr_accessor :name
      
      def initialize(*args)
        super unless args.empty?
        @surrounding_modules = []
        @named_expressions = {}
        @pos_var_counter = 0
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

        methods = []
        methods.push "def parse(input)", ["#{root_rule.name}(input, 0) == input.size"], "end", ""
        
        methods.concat @named_expressions.values.select(&:has_own_method?).map { |expr|
          pos_var = new_position
          matcher = expr.create_matcher self, pos_var
          code = matcher.code
          code.last.append_code " && #{matcher.exit_pos}"
          ["def #{expr.name}(input, #{pos_var})", code, "end", ""]
        }.flatten(1)

        parser_class = ["class #{@name}Parser", methods, "end"]
        
        output_array = @surrounding_modules.reverse.inject(parser_class) { |content, mod| ["module #{mod}", content, "end"] }

        output = ""
        write_array = lambda { |array, indention|
          array.each do |part|
            case part
            when String
              output << "#{'  ' * indention}#{part}\n"
            when Array
              write_array.call part, indention + 1
            else
              raise ArgumenrError
            end
          end
        }
        write_array.call output_array, 0
        
        output
      end
      
      def new_position
        @pos_var_counter += 1
        Position.new("pos#{@pos_var_counter}", 0)
      end
    end

    class ParsingExpression < Treetop::Runtime::SyntaxNode
      attr_accessor :name, :own_method_requested, :recursive, :reference_count
      
      def initialize(*args)
        super
        @own_method_requested = false
        @recursive = false
        @reference_count = 0
      end
      
      def grammar
        element = parent
        element = element.parent while not element.is_a?(Grammar)
        element
      end
      
      def mark_recursions(inside_expressions)
        return if @recursive
        
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
        @own_method_requested || @recursive || @reference_count >= 10
      end
      
      def fixed_length
        nil
      end
      
      def first_character_class
        nil
      end
    end
    
    class Sequence < ParsingExpression
      def children
        @children ||= ([head] + tail.elements).map { |child| child.expression }
      end
      
      def fixed_length
        @fixed_length ||= begin
          lengths = children.map(&:fixed_length)
          lengths.all? ? lengths.reduce(0, :+) : nil
        end
      end
      
      def first_character_class
        children.first && children.first.first_character_class
      end
      
      def create_matcher(context, entry_pos)
        case children.size
        when 0
          Matcher.new ["true"], entry_pos
        when 1
          children.first.create_matcher context, entry_pos
        else
          code = []
          pos = entry_pos
          children.each_index do |i|
            matcher = children[i].create_matcher context, pos
            pos = matcher.exit_pos
            code.concat matcher.code
            code.last.append_code " &&" if i < children.size - 1
          end
          Matcher.new ["( # sequence", code, ")"], pos
        end
      end
    end
    
    class Choice < ParsingExpression
      def children
        @children ||= [head] + tail.elements.map(&:alternative)
      end
      
      def fixed_length
        @fixed_length ||= begin
          lengths = children.map(&:fixed_length).uniq
          lengths.size == 1 ? lengths.first : nil
        end
      end
      
      def first_character_class
        @first_character_class ||= begin
          classes = @children.map(&:first_character_class)
          classes.all? ? classes.join : nil
        end
      end
      
      def create_matcher(context, entry_pos)
        if fixed_length
          code = []
          children.each_index do |i|
            matcher = children[i].create_matcher context, entry_pos
            code.concat matcher.code
            code.last.append_code " ||" if i < children.size - 1
          end
          Matcher.new ["( # choice", code, ")"], entry_pos + fixed_length
        else
          code = []
          children.each_index do |i|
            matcher = children[i].create_matcher context, entry_pos
            child_code = []
            child_code.concat matcher.code
            child_code.last.append_code " &&"
            child_code << matcher.exit_pos.to_s
            code.push "(", child_code, ")"
            code.last.append_code " ||" if i < children.size - 1
          end
          pos_var = context.new_position
          Matcher.new ["(#{pos_var} = ( # choice", code, "))"], pos_var
        end
      end
    end
    
    class Optional < ParsingExpression
      def children
        [expression]
      end
      
      def create_matcher(context, entry_pos)
        pos_var = context.new_position
        
        matcher = expression.create_matcher context, entry_pos
        code = matcher.code
        
        code.first.insert 0, "(#{pos_var} = ("
        code.last << " && #{matcher.exit_pos}) || #{entry_pos})"
        
        Matcher.new code, pos_var
      end
    end
    
    class Repetition < ParsingExpression
      def children
        [expression]
      end
      
      def create_matcher(context, entry_pos)
        code = []
        pos_var = context.new_position
        code << "#{pos_var} = #{entry_pos}"
        
        matcher = expression.create_matcher context, pos_var
        
        exit_pos_assignment = if matcher.exit_pos.variable == pos_var.variable
          "#{pos_var} += #{matcher.exit_pos.offset}"
        else
          "#{pos_var} = #{matcher.exit_pos}"
        end
        
        first_character_guard = if expression.first_character_class && expression.first_character_class.size < 10
          "input[#{pos_var}, 1] =~ /[#{expression.first_character_class.gsub('/', '\/')}]/ && "
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
    end
    
    class PositiveLookahead < Lookahead
      def create_matcher(context, entry_pos)
        matcher = expression.create_matcher context, entry_pos
        Matcher.new matcher.code, entry_pos
      end
    end
    
    class NegativeLookahead < Lookahead
      def create_matcher(context, entry_pos)
        matcher = expression.create_matcher context, entry_pos
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
      
      def create_matcher(context, entry_pos)
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
      
      def create_matcher(context, entry_pos)
        Matcher.new ["(input[#{entry_pos}, #{string.size}] == #{string.inspect})"], entry_pos + string.size
      end
    end
    
    class CharacterClassTerminal < Terminal
      def pattern
        characters.text_value
      end
      
      def fixed_length
        1
      end
      
      def first_character_class
        pattern[0, 1] != '^' ? pattern : nil
      end
      
      def create_matcher(context, entry_pos)
        Matcher.new ["(input[#{entry_pos}, 1] =~ /[#{pattern.gsub('/', '\/')}]/)"], entry_pos + 1
      end
    end
    
    class RuleName < ParsingExpression
      def referenced_expression
        @referenced_expression ||= begin
          exp = grammar.find_expression name.text_value
          exp.reference_count += 1
          exp
        end
      end
      
      def children
        [referenced_expression]
      end
      
      def fixed_length
        referenced_expression.recursive ? nil : referenced_expression.fixed_length
      end

      def first_character_class
        referenced_expression.recursive ? nil : referenced_expression.first_character_class
      end

      def create_matcher(context, entry_pos)
        if referenced_expression.has_own_method?
          pos_var = context.new_position
          Matcher.new ["(#{pos_var} = #{name.text_value}(input, #{entry_pos}))"], pos_var
        else
          referenced_expression.create_matcher context, entry_pos
        end
      end
    end
    
    class ParenthesizedExpression < ParsingExpression
      def children
        [expression]
      end
      
      def fixed_length
        expression.fixed_length
      end
      
      def first_character_class
        expression.first_character_class
      end
      
      def create_matcher(context, entry_pos)
        expression.create_matcher context, entry_pos
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