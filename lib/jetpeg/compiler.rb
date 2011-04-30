require "treetop"
require "jetpeg/compiler/metagrammar"

require 'llvm/core'
require 'llvm/execution_engine'
require 'llvm/transforms/scalar'

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
      
      mod = LLVM::Module.create("Parser")

      function = mod.functions.add("rule", [LLVM::Pointer(LLVM::Int8), LLVM::Int], LLVM::Int1) do |the_function, input, length|
        entry = the_function.basic_blocks.append "entry"
        
        builder = LLVM::Builder.create
        builder.position_at_end(entry)
        
        failed_block = builder.create_block "failed"
        
        input_current = expression.build builder, input, failed_block
        input_end = builder.gep input, length, "input_end"
        at_end = builder.icmp :eq, input_current, input_end, "at_end"
        builder.ret at_end
        
        builder.position_at_end failed_block
        builder.ret LLVM::FALSE

        the_function.verify
      end

      mod.verify
      
      engine = LLVM::ExecutionEngine.create_jit_compiler(mod)
      
      optimize = false
      if optimize
        pass_manager = LLVM::PassManager.new engine
        pass_manager.instcombine!
        pass_manager.reassociate!
        pass_manager.gvn!
        pass_manager.simplifycfg!
        pass_manager.run mod
      end
      
      CompiledRule.new(engine, function)
    end
    
    class CompiledRule
      def initialize(engine, function)
        @engine = engine
        @function = function
      end
      
      def match(input)
        input_ptr = FFI::MemoryPointer.from_string input
        @engine.run_function(@function, input_ptr, input.size).to_b
      end
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
            
      def compile(root_rule_name = nil) # TODO not functional atm
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
      
      def build(builder, start_input, failed_block)
        children.inject(start_input) do |input, child|
          child.build builder, input, failed_block
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
      
      def build(builder, start_input, failed_block)
        successful_block = builder.create_block "choice_successful"
        phi_values = []
        
        children.each do |child|
          next_child_block = builder.create_block "choice_next_child"
          input = child.build builder, start_input, next_child_block
          phi_values.push input, builder.insert_block
          builder.br successful_block
          
          builder.position_at_end next_child_block
        end
        builder.br failed_block
        
        builder.position_at_end successful_block
        builder.phi LLVM::Pointer(LLVM::Int8), *phi_values, "choice_end_input"
      end
    end
    
    class Optional < ParsingExpression
      def children
        [expression]
      end
      
      def build(builder, start_input, failed_block)
        exit_block = builder.create_block "optional_exit"
        
        optional_failed_block = builder.create_block "optional_failed"
        input = expression.build builder, start_input, optional_failed_block
        optional_successful_block = builder.insert_block
        builder.br exit_block
        
        builder.position_at_end optional_failed_block
        builder.br exit_block
        
        builder.position_at_end exit_block
        builder.phi LLVM::Pointer(LLVM::Int8), start_input, optional_failed_block, input, optional_successful_block, "optional_end_input"
      end
    end
    
    class ZeroOrMore < ParsingExpression
      def children
        [expression]
      end
      
      def build(builder, start_input, failed_block)
        start_block = builder.insert_block
        loop_block = builder.create_block "repetition_loop"
        exit_block = builder.create_block "repetition_exit"
        builder.br loop_block
        
        builder.position_at_end loop_block
        input = builder.phi LLVM::Pointer(LLVM::Int8), start_input, start_block, "loop_input"
        next_input = expression.build builder, input, exit_block
        input.add_incoming next_input, builder.insert_block
        builder.br loop_block
        
        builder.position_at_end exit_block
        input
      end
    end
    
    class OneOrMore < ZeroOrMore
      def build(builder, start_input, failed_block)
        input = expression.build builder, start_input, failed_block
        super builder, input, failed_block
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
      def build(builder, start_input, failed_block)
        expression.build builder, start_input, failed_block
        start_input
      end
    end
    
    class NegativeLookahead < Lookahead
      def build(builder, start_input, failed_block)
        lookahead_failed_block = builder.create_block "lookahead_failed"

        expression.build builder, start_input, lookahead_failed_block
        builder.br failed_block
        
        builder.position_at_end lookahead_failed_block
        start_input
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
      
      def build(builder, start_input, failed_block)
        builder.gep start_input, LLVM::Int(1), "new_input"
      end
    end
    
    class StringTerminal < Terminal
      def string
        @string ||= eval text_value # TODO avoid eval here
      end
      
      def fixed_length
        string.size
      end
      
      def build(builder, start_input, failed_block)
        string.chars.inject(start_input) do |input, char|
          input_char = builder.load input, "char"
          matching = builder.icmp :eq, input_char, LLVM::Int8.from_i(char.ord), "matching"
          next_char_block = builder.create_block "string_terminal_next_char"
          builder.cond matching, next_char_block, failed_block
          
          builder.position_at_end next_char_block
          builder.gep input, LLVM::Int(1), "new_input"
        end
      end
    end
    
    class CharacterClassTerminal < Terminal
      def pattern
        characters.text_value
      end
      
      def fixed_length
        1
      end
      
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
        
        builder.gep start_input, LLVM::Int(1), "new_input"
      end
    end
    
    class CharacterClassSingleCharacter < Treetop::Runtime::SyntaxNode
      def build(builder, input_char, successful_block, failed_block)
        matching = builder.icmp :eq, input_char, LLVM::Int8.from_i(char.text_value.ord), "matching"
        builder.cond matching, successful_block, failed_block
      end
    end
    
    class CharacterClassRange < Treetop::Runtime::SyntaxNode
      def build(builder, input_char, successful_block, failed_block)
        begin_char_successful = builder.create_block "character_class_range_begin_char_successful"
        matching = builder.icmp :uge, input_char, LLVM::Int8.from_i(begin_char.char.text_value.ord), "begin_matching"
        builder.cond matching, begin_char_successful, failed_block
        builder.position_at_end begin_char_successful
        matching = builder.icmp :ule, input_char, LLVM::Int8.from_i(end_char.char.text_value.ord), "end_matching"
        builder.cond matching, successful_block, failed_block
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
      
      def build(builder, start_input, failed_block)
        expression.build builder, start_input, failed_block
      end
    end
  end
end