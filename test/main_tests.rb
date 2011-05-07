require 'test/unit'
require "jetpeg"

class MainTests < Test::Unit::TestCase
  def test_string_terminal
    rule = JetPEG::Compiler.compile_rule "'abc'"
    assert rule.match("abc")
    assert !rule.match("ab")
    assert !rule.match("Xbc")
    assert !rule.match("abX")
    assert !rule.match("abcX")
  end
  
  def test_any_character_terminal
    rule = JetPEG::Compiler.compile_rule "."
    assert rule.match("a")
    assert rule.match("B")
    assert rule.match("5")
    assert !rule.match("")
    assert !rule.match("99")
  end
  
  def test_character_class_terminal
    rule = JetPEG::Compiler.compile_rule "[b-df\\-h]"
    assert rule.match("b")
    assert rule.match("c")
    assert rule.match("d")
    assert rule.match("f")
    assert rule.match("-")
    assert rule.match("h")
    assert !rule.match("a")
    assert !rule.match("e")
    assert !rule.match("g")
    
    rule = JetPEG::Compiler.compile_rule "[^a]"
    assert rule.match("b")
    assert !rule.match("a")
    
    rule = JetPEG::Compiler.compile_rule "[\\n]"
    assert rule.match("\n")
    assert !rule.match("n")
  end
  
  def test_sequence
    rule = JetPEG::Compiler.compile_rule "'abc' 'def'"
    assert rule.match("abcdef")
    assert !rule.match("abcde")
    assert !rule.match("aXcdef")
    assert !rule.match("abcdXf")
    assert !rule.match("abcdefX")
  end
  
  def test_choice
    rule = JetPEG::Compiler.compile_rule "'abc' / 'def'"
    assert rule.match("abc")
    assert rule.match("def")
    assert !rule.match("ab")
    assert !rule.match("aXc")
    assert !rule.match("defX")
  end
  
  def test_optional
    rule = JetPEG::Compiler.compile_rule "'abc'? 'def'"
    assert rule.match("abcdef")
    assert rule.match("def")
    assert !rule.match("abc")
    assert !rule.match("aXcdef")
    assert !rule.match("abdef")
  end
  
  def test_zero_or_more
    rule = JetPEG::Compiler.compile_rule "'a'*"
    assert rule.match("")
    assert rule.match("a")
    assert rule.match("aaaaa")
    assert !rule.match("X")
    assert !rule.match("aaaX")
  end
  
  def test_one_or_more
    rule = JetPEG::Compiler.compile_rule "'a'+"
    assert rule.match("a")
    assert rule.match("aaaaa")
    assert !rule.match("")
    assert !rule.match("X")
    assert !rule.match("aaaX")
  end
  
  def test_parenthesized_expression
    rule = JetPEG::Compiler.compile_rule "('a' 'b')? 'c'"
    assert rule.match("abc")
    assert rule.match("c")
    assert !rule.match("ac")
    assert !rule.match("bc")
  end
  
  def test_positive_lookahead
    rule = JetPEG::Compiler.compile_rule "(&'a') ."
    assert rule.match("a")
    assert !rule.match("")
    assert !rule.match("X")
    assert !rule.match("aX")
  end
  
  def test_negative_lookahead
    rule = JetPEG::Compiler.compile_rule "(!'a') ."
    assert rule.match("X")
    assert !rule.match("")
    assert !rule.match("a")
    assert !rule.match("XX")
  end
  
  def test_rule_definition
    grammar = JetPEG::Compiler.compile_grammar "
      rule test
        'a'
      end
    "
    assert grammar["test"].match("a")
    assert !grammar["test"].match("X")
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
    assert grammar["test"].match("b")
    assert !grammar["test"].match("X")
    assert !grammar["test"].match("a")
  end
  
  def test_recursive_rule
    grammar = JetPEG::Compiler.compile_grammar "
      rule test
        '(' test ')' / ''
      end
    "
    assert grammar["test"].match("")
    assert grammar["test"].match("()")
    assert grammar["test"].match("((()))")
    assert !grammar["test"].match("()))")
    assert !grammar["test"].match("((()")
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
    assert rule.match("abc") == { word: "abc" }
    
    rule = JetPEG::Compiler.compile_rule "(word:[abc]+)?"
    assert rule.match("abc") == { word: "abc" }
  end
  
  def test_nested_label
    rule = JetPEG::Compiler.compile_rule "word:('a' char:. 'c')"
    assert rule.match("abc") == { word: { char: "b" } }
  end
  
  def test_at_label
    rule = JetPEG::Compiler.compile_rule "'a' @:. 'c'"
    assert rule.match("abc") == "b"
    
    rule = JetPEG::Compiler.compile_rule "char:('a' @:. 'c')"
    assert rule.match("abc") == { char: "b" }
  end
  
  def test_label_merge
    rule = JetPEG::Compiler.compile_rule "char:'a' / char:'b' / 'c'"
    assert rule.match("a") == { char: "a" }
    assert rule.match("b") == { char: "b" }
    assert rule.match("c") == { char: nil }
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
    assert grammar["test"].match("abcd") == { d: nil, char: "a", word: { d: nil, char: "c" }, a: { d: "d" , char: nil} }
  end
  
  def test_recursive_rule_with_label
    grammar = JetPEG::Compiler.compile_grammar "
      rule test
        '(' inner:(test (other:'b')?) ')' / char:'a'
      end
    "
    assert grammar["test"].match("((a)b)") == { inner: { inner: { inner: nil, char: "a", other: nil }, char: nil, other: "b"}, char: nil }
  end
  
  def test_repetition_with_label
    rule = JetPEG::Compiler.compile_rule "list:(char:('a' / 'b' / 'c'))*"
    assert rule.match("abc") == { list: [{ char: "a" }, { char: "b" }, { char: "c" }] }
    
    rule = JetPEG::Compiler.compile_rule "list:(char:'a' / char:'b' / 'c')+"
    assert rule.match("abc") == { list: [{ char: "a" }, { char: "b" }, { char: nil }] }
  end
  
  def test_invalid_labels
    assert_raise SyntaxError do
      JetPEG::Compiler.compile_rule "char:'a' 'b' char:'c'"
    end
    
    assert_raise SyntaxError do
      JetPEG::Compiler.compile_rule "@:'a' 'b' char:'c'"
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
    rule.parser.class_scope = self.class
    assert rule.match("abc") == TestClassA.new({ char: "b" })
    assert rule.match("def") == TestClassB.new({ char: "e" })
  end
end