require 'test/unit'
require "jetpeg"
JetPEG::Parser.default_options[:raise_on_failure] = false

class LabelsTests < Test::Unit::TestCase
  def test_label
    rule = JetPEG::Compiler.compile_rule "'a' char:. 'c' / 'def'"
    result = rule.match "abc"
    assert result == { char: "b" }
    assert result[:char] == "b"
    assert result[:char] === "b"
    assert "b" == result[:char]
    assert "b" === result[:char]
    
    rule = JetPEG::Compiler.compile_rule "word:( 'a' 'b' 'c' )"
    assert rule.match("abc") == { word: "abc" }
    
    rule = JetPEG::Compiler.compile_rule "( word:[abc]+ )?"
    assert rule.match("abc") == { word: "abc" }
  end
  
  def test_nested_label
    rule = JetPEG::Compiler.compile_rule "word:( 'a' char:. 'c' )"
    assert rule.match("abc") == { word: { char: "b" } }
  end
  
  def test_at_label
    rule = JetPEG::Compiler.compile_rule "'a' @:. 'c'"
    assert rule.match("abc") == "b"
    
    grammar = JetPEG::Compiler.compile_grammar "
      rule test
        char:a
      end
      rule a
        'a' @:a 'c' / @:'b'
      end
    "
    assert grammar[:test].match("abc") == { char: "b" }
  end
  
  def test_label_merge
    rule = JetPEG::Compiler.compile_rule "( char:'a' x:'x' / 'b' x:'x' / char:( inner:'c' ) x:'x' ) / 'y'"
    assert rule.match("ax") == { char: "a", x: "x" }
    assert rule.match("bx") == { char: nil, x: "x" }
    assert rule.match("cx") == { char: { inner: "c" }, x: "x" }
  end
  
  def test_rule_with_label
    grammar = JetPEG::Compiler.compile_grammar "
      rule test
        a word:( 'b' a ) :a
      end
      rule a
        d:'d' / char:.
      end
    "
    assert grammar[:test].match("abcd") == { d: nil, char: "a", word: { d: nil, char: "c" }, a: { d: "d" , char: nil} }
  end
  
  def test_recursive_rule_with_label
    grammar = JetPEG::Compiler.compile_grammar "
      rule test
        '(' inner:( test ( other:'b' )? ) ')' / char:'a'
      end
    "
    assert grammar[:test].match("((a)b)") == { inner: { inner: { inner: nil, char: "a", other: nil }, char: nil, other: "b"}, char: nil }
    
    grammar = JetPEG::Compiler.compile_grammar "
      rule test
        '(' test2 ')' / char:'a'
      end
      rule test2
        a:test b:test
      end
    "
    assert grammar[:test].match("((aa)(aa))")
  end
  
  def test_repetition_with_label
    rule = JetPEG::Compiler.compile_rule "list:( char:( 'a' / 'b' / 'c' ) )*"
    assert rule.match("abc") == { list: [{ char: "a" }, { char: "b" }, { char: "c" }] }
    
    rule = JetPEG::Compiler.compile_rule "list:( char:'a' / char:'b' / 'c' )+"
    assert rule.match("abc") == { list: [{ char: "a" }, { char: "b" }, { char: nil }] }
    
    rule = JetPEG::Compiler.compile_rule "( 'a' / 'b' / 'c' )+"
    assert rule.match("abc") == {}
    
    rule = JetPEG::Compiler.compile_rule "list:('a' char:.)*['ada' final:.]"
    assert rule.match("abacadae") == { list: [{ char: "b", final: nil }, { char: "c", final: nil }, { char: nil, final: "e" }] }
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
    assert rule.match("abc", class_scope: self.class) == TestClassA.new({ char: "b" })
    assert rule.match("def", class_scope: self.class) == TestClassB.new({ char: "e" })
  end
  
  def test_value_creator
    rule = JetPEG::Compiler.compile_rule "
      'a' char:. 'c' { char.upcase } /
      word:'def' { word.chars.map { |c| c.ord } } /
      'ghi' { [__FILE__, __LINE__] }
    ", "test.jetpeg"
    assert rule.match("abc") == "B"
    assert rule.match("def") == ["d".ord, "e".ord, "f".ord]
    assert rule.match("ghi") == ["test.jetpeg", 4]
  end
  
  #def test_local_label
  #  rule = JetPEG::Compiler.compile_rule "'a' %temp:. 'c' char:%temp"
  #  result = rule.match "abc"
  #  assert result == { char: "b" }
  #end
  
end