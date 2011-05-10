require 'test/unit'
require "jetpeg"

class MainTests < Test::Unit::TestCase
  def test_string_terminal
    rule = JetPEG::Compiler.compile_rule "'abc'"
    assert rule.match("abc", false)
    assert !rule.match("ab", false)
    assert !rule.match("Xbc", false)
    assert !rule.match("abX", false)
    assert !rule.match("abcX", false)
  end
  
  def test_character_class_terminal
    rule = JetPEG::Compiler.compile_rule "[b-df\\-h]"
    assert rule.match("b", false)
    assert rule.match("c", false)
    assert rule.match("d", false)
    assert rule.match("f", false)
    assert rule.match("-", false)
    assert rule.match("h", false)
    assert !rule.match("a", false)
    assert !rule.match("e", false)
    assert !rule.match("g", false)
    
    rule = JetPEG::Compiler.compile_rule "[^a]"
    assert rule.match("b", false)
    assert !rule.match("a", false)
    
    rule = JetPEG::Compiler.compile_rule "[\\n]"
    assert rule.match("\n", false)
    assert !rule.match("n", false)
  end
    
  def test_any_character_terminal
    rule = JetPEG::Compiler.compile_rule "."
    assert rule.match("a", false)
    assert rule.match("B", false)
    assert rule.match("5", false)
    assert !rule.match("", false)
    assert !rule.match("99", false)
    
    rule = JetPEG::Compiler.compile_rule ".*"
    assert rule.match("aaa", false)
  end
  
  def test_sequence
    rule = JetPEG::Compiler.compile_rule "'abc' 'def'"
    assert rule.match("abcdef", false)
    assert !rule.match("abcde", false)
    assert !rule.match("aXcdef", false)
    assert !rule.match("abcdXf", false)
    assert !rule.match("abcdefX", false)
  end
  
  def test_choice
    rule = JetPEG::Compiler.compile_rule "'abc' / 'def'"
    assert rule.match("abc", false)
    assert rule.match("def", false)
    assert !rule.match("ab", false)
    assert !rule.match("aXc", false)
    assert !rule.match("defX", false)
  end
  
  def test_optional
    rule = JetPEG::Compiler.compile_rule "'abc'? 'def'"
    assert rule.match("abcdef", false)
    assert rule.match("def", false)
    assert !rule.match("abc", false)
    assert !rule.match("aXcdef", false)
    assert !rule.match("abdef", false)
  end
  
  def test_zero_or_more
    rule = JetPEG::Compiler.compile_rule "'a'*"
    assert rule.match("", false)
    assert rule.match("a", false)
    assert rule.match("aaaaa", false)
    assert !rule.match("X", false)
    assert !rule.match("aaaX", false)
  end
  
  def test_one_or_more
    rule = JetPEG::Compiler.compile_rule "'a'+"
    assert rule.match("a", false)
    assert rule.match("aaaaa", false)
    assert !rule.match("", false)
    assert !rule.match("X", false)
    assert !rule.match("aaaX", false)
  end
  
  def test_parenthesized_expression
    rule = JetPEG::Compiler.compile_rule "('a' 'b')? 'c'"
    assert rule.match("abc", false)
    assert rule.match("c", false)
    assert !rule.match("ac", false)
    assert !rule.match("bc", false)
  end
  
  def test_positive_lookahead
    rule = JetPEG::Compiler.compile_rule "&'a' ."
    assert rule.match("a", false)
    assert !rule.match("", false)
    assert !rule.match("X", false)
    assert !rule.match("aX", false)
  end
  
  def test_negative_lookahead
    rule = JetPEG::Compiler.compile_rule "!'a' ."
    assert rule.match("X", false)
    assert !rule.match("", false)
    assert !rule.match("a", false)
    assert !rule.match("XX", false)
  end
  
  def test_rule_definition
    grammar = JetPEG::Compiler.compile_grammar "
      rule test
        'a'
      end
    "
    assert grammar[:test].match("a", false)
    assert !grammar[:test].match("X", false)
  end
  
  def test_rule_reference
    grammar = JetPEG::Compiler.compile_grammar "
      rule test
        a
      end
      rule a
        'b'
      end
    "
    assert grammar[:test].match("b", false)
    assert !grammar[:test].match("X", false)
    assert !grammar[:test].match("a", false)
  end
  
  def test_recursive_rule
    grammar = JetPEG::Compiler.compile_grammar "
      rule test
        '(' test ')' / ''
      end
    "
    assert grammar[:test].match("", false)
    assert grammar[:test].match("()", false)
    assert grammar[:test].match("((()))", false)
    assert !grammar[:test].match("()))", false)
    assert !grammar[:test].match("((()", false)
  end
  
  def test_label
    rule = JetPEG::Compiler.compile_rule "'a' char:. 'c' / 'def'"
    result = rule.match "abc"
    assert result == { char: "b" }
    assert result[:char] == "b"
    assert result[:char] === "b"
    assert "b" == result[:char]
    assert "b" === result[:char]
    
    rule = JetPEG::Compiler.compile_rule "word:('a' 'b' 'c')"
    assert rule.match("abc", false) == { word: "abc" }
    
    rule = JetPEG::Compiler.compile_rule "(word:[abc]+)?"
    assert rule.match("abc", false) == { word: "abc" }
  end
  
  def test_nested_label
    rule = JetPEG::Compiler.compile_rule "word:('a' char:. 'c')"
    assert rule.match("abc", false) == { word: { char: "b" } }
  end
  
  def test_at_label
    rule = JetPEG::Compiler.compile_rule "'a' @:. 'c'"
    assert rule.match("abc", false) == "b"
    
    grammar = JetPEG::Compiler.compile_grammar "
      rule test
        char:a
      end
      rule a
        'a' @:a 'c' / @:'b'
      end
    "
    assert grammar[:test].match("abc", false) == { char: "b" }
  end
  
  def test_label_merge
    rule = JetPEG::Compiler.compile_rule "(char:'a' x:'x' / 'b' x:'x' / char:(inner:'c') x:'x') / 'y'"
    assert rule.match("ax", false) == { char: "a", x: "x" }
    assert rule.match("bx", false) == { char: nil, x: "x" }
    assert rule.match("cx", false) == { char: { inner: "c" }, x: "x" }
  end
  
  def test_rule_with_label
    grammar = JetPEG::Compiler.compile_grammar "
      rule test
        a word:('b' a) :a
      end
      rule a
        d:'d' / char:.
      end
    "
    assert grammar[:test].match("abcd", false) == { d: nil, char: "a", word: { d: nil, char: "c" }, a: { d: "d" , char: nil} }
  end
  
  def test_recursive_rule_with_label
    grammar = JetPEG::Compiler.compile_grammar "
      rule test
        '(' inner:(test (other:'b')?) ')' / char:'a'
      end
    "
    assert grammar[:test].match("((a)b)", false) == { inner: { inner: { inner: nil, char: "a", other: nil }, char: nil, other: "b"}, char: nil }
    
    grammar = JetPEG::Compiler.compile_grammar "
      rule test
        '(' test2 ')' / char:'a'
      end
      rule test2
        a:test b:test
      end
    "
    assert grammar[:test].match("((aa)(aa))", false)
  end
  
  def test_repetition_with_label
    rule = JetPEG::Compiler.compile_rule "list:(char:('a' / 'b' / 'c'))*"
    assert rule.match("abc", false) == { list: [{ char: "a" }, { char: "b" }, { char: "c" }] }
    
    rule = JetPEG::Compiler.compile_rule "list:(char:'a' / char:'b' / 'c')+"
    assert rule.match("abc", false) == { list: [{ char: "a" }, { char: "b" }, { char: nil }] }
    
    rule = JetPEG::Compiler.compile_rule "('a' / 'b' / 'c')+"
    assert rule.match("abc", false) == {}
  end
  
  def test_compilation_errors
    assert_raise JetPEG::CompilationError do
      JetPEG::Compiler.compile_rule "missing_rule"
    end

    assert_raise JetPEG::CompilationError do
      JetPEG::Compiler.compile_rule "char:'a' 'b' char:'c'"
    end
    
    assert_raise JetPEG::CompilationError do
      JetPEG::Compiler.compile_rule "@:'a' 'b' char:'c'"
    end
    
    assert_raise JetPEG::CompilationError do
      grammar = JetPEG::Compiler.compile_grammar "
        rule test
          '(' test ')' / char:'a'
        end
      "
    end
  end
  
  class TestClass
    attr_reader :data
    
    def initialize(data)
      @data = data
    end
    
    def ==(other)
      (other.class == self.class) && (other.data == @data)
    end
  end
  
  class TestClassA < TestClass
  end
  
  class TestClassB < TestClass
  end
  
  def test_object_creator
    rule = JetPEG::Compiler.compile_rule "'a' char:. 'c' <TestClassA> / 'd' char:. 'f' <TestClassB>"
    assert JetPEG.realize_data(rule.match("abc", false), self.class) == TestClassA.new({ char: "b" })
    assert JetPEG.realize_data(rule.match("def", false), self.class) == TestClassB.new({ char: "e" })
  end
  
  def test_value_creator
    rule = JetPEG::Compiler.compile_rule "'a' char:. 'c' { char.upcase } / word:'def' { word.chars.map { |c| c.ord } }"
    assert JetPEG.realize_data(rule.match("abc", false), self.class) == "B"
    assert JetPEG.realize_data(rule.match("def", false), self.class) == ["d".ord, "e".ord, "f".ord]
  end
  
  def test_failure_tracing
    rule = JetPEG::Compiler.compile_rule "'a' 'b' 'c'"
    assert !rule.match("aXc", false)
    assert rule.parser.failure_reason.is_a? JetPEG::ParsingError
    assert rule.parser.failure_reason.position == 1
    assert rule.parser.failure_reason.expectations == ["b"]
    
    rule = JetPEG::Compiler.compile_rule "'a' [b2-5] 'c'"
    assert !rule.match("aXc", false)
    assert rule.parser.failure_reason.is_a? JetPEG::ParsingError
    assert rule.parser.failure_reason.position == 1
    assert rule.parser.failure_reason.expectations == ["2-5", "b"]
  end
  
  def test_root_switching
    grammar = JetPEG::Compiler.compile_grammar "
      rule test1
        'abc' / test2
      end
      rule test2
        'def'
      end
    "
    assert grammar[:test1].match("abc", false)
    assert grammar[:test2].match("def", false)
  end
end