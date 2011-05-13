require 'test/unit'
require "jetpeg"

class LabelsTests < Test::Unit::TestCase
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
end