require 'test/unit'
require "jetpeg"
JetPEG::Parser.default_options[:raise_on_failure] = false
JetPEG::Parser.default_options[:track_malloc] = true

class LabelsTests < Test::Unit::TestCase
  def test_label
    rule = JetPEG::Compiler.compile_rule "'a' char:. 'c' / 'def'"
    result = rule.parse "abc"
    assert result == { char: "b" }
    assert result[:char] == "b"
    assert result[:char] === "b"
    assert "b" == result[:char]
    assert "b" === result[:char]
    
    rule = JetPEG::Compiler.compile_rule "word:( 'a' 'b' 'c' )"
    assert rule.parse("abc") == { word: "abc" }
    
    rule = JetPEG::Compiler.compile_rule "( word:[abc]+ )?"
    assert rule.parse("abc") == { word: "abc" }
    assert rule.parse("") == {}
    
    rule = JetPEG::Compiler.compile_rule "'a' outer:( inner:. ) 'c' / 'def'"
    assert rule.parse("abc") == { outer: { inner: "b" } }
  end
  
  def test_nested_label
    rule = JetPEG::Compiler.compile_rule "word:( 'a' char:. 'c' )"
    assert rule.parse("abc") == { word: { char: "b" } }
  end
  
  def test_at_label
    rule = JetPEG::Compiler.compile_rule "'a' @:. 'c'"
    assert rule.parse("abc") == "b"
    
    grammar = JetPEG::Compiler.compile_grammar "
      rule test
        char:a
      end
      rule a
        'a' @:a 'c' / @:'b'
      end
    "
    assert grammar.parse_rule(:test, "abc") == { char: "b" }
  end
  
  def test_label_merge
    rule = JetPEG::Compiler.compile_rule "( char:'a' x:'x' / 'b' x:'x' / char:( inner:'c' ) x:'x' ) / 'y'"
    assert rule.parse("ax") == { char: "a", x: "x" }
    assert rule.parse("bx") == { x: "x" }
    assert rule.parse("cx") == { char: { inner: "c" }, x: "x" }
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
    assert grammar.parse_rule(:test, "abcd") == { char: "a", word: { char: "c" }, a: { d: "d" } }
  end
  
  def test_recursive_rule_with_label
    grammar = JetPEG::Compiler.compile_grammar "
      rule test
        '(' inner:( test ( other:'b' )? ) ')' / char:'a'
      end
    "
    assert grammar.parse_rule(:test, "((a)b)") == { inner: { inner: { char: "a" }, other: "b"} }

    grammar = JetPEG::Compiler.compile_grammar "
      rule test
        '(' test ')' / char:'a'
      end
    "
    assert grammar.parse_rule(:test, "((a))") == { char: "a" }
    
    grammar = JetPEG::Compiler.compile_grammar "
      rule test
        '(' test2 ')' / char:'a'
      end
      rule test2
        a:test b:test
      end
    "
    assert grammar.parse_rule(:test, "((aa)(aa))") == { a: { a: { char: "a" }, b: { char: "a" }}, b: { a: { char: "a" }, b: { char: "a" } } }
  end
  
  def test_repetition_with_label
    rule = JetPEG::Compiler.compile_rule "list:( char:( 'a' / 'b' / 'c' ) )*"
    assert rule.parse("abc") == { list: [{ char: "a" }, { char: "b" }, { char: "c" }] }
    
    rule = JetPEG::Compiler.compile_rule "list:( char:'a' / char:'b' / 'c' )+"
    assert rule.parse("abc") == { list: [{ char: "a" }, { char: "b" }, nil] }
    
    rule = JetPEG::Compiler.compile_rule "( 'a' / 'b' / 'c' )+"
    assert rule.parse("abc") == {}
    
    rule = JetPEG::Compiler.compile_rule "list:( 'a' char:. )*->( 'ada' final:. )"
    assert rule.parse("abacadae") == { list: [{ char: "b" }, { char: "c" }, { final: "e" }] }
    
    grammar = JetPEG::Compiler.compile_grammar "
      rule test
        ( char1:'a' inner:test / 'b' )*
      end
    "
    assert grammar.parse_rule(:test, "ab")
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
    assert rule.parse("abc", class_scope: self.class) == TestClassA.new({ char: "b" })
    assert rule.parse("def", class_scope: self.class) == TestClassB.new({ char: "e" })
    
    rule = JetPEG::Compiler.compile_rule "'a' char:. 'c' <TestClassA { a: 'test1', b: [ <TestClassB true>, <TestClassB { r: @char }> ] }>"
    assert rule.parse("abc", class_scope: self.class) == TestClassA.new({ a: "test1", b: [ TestClassB.new(true), TestClassB.new({ r: "b" }) ] })
  end
  
  def test_value_creator
    rule = JetPEG::Compiler.compile_rule "
      'a' char:. 'c' { @char.upcase } /
      word:'def' { @word.chars.map { |c| c.ord } } /
      'ghi' { [__FILE__, __LINE__] }
    ", "test.jetpeg"
    assert rule.parse("abc") == "B"
    assert rule.parse("def") == ["d".ord, "e".ord, "f".ord]
    assert rule.parse("ghi") == ["test.jetpeg", 4]
  end
  
  def test_local_label
    rule = JetPEG::Compiler.compile_rule "'a' %temp:( char:'b' )* 'c' ( result:%temp )"
    assert rule.parse("abc") == { result: [{ char: "b" }] }
    assert rule.parse("abX") == nil
    
    rule = JetPEG::Compiler.compile_rule "'a' %temp:( char:'b' )* 'c' result1:%temp result2:%temp"
    assert rule.parse("abc") == { result1: [{ char: "b" }], result2: [{ char: "b" }] }
  end
  
  # def test_parameters
  #   grammar = JetPEG::Compiler.compile_grammar "
  #     rule test
  #       %a:. test2[%a]
  #     end
  #     rule test2[%v]
  #       result:%v
  #     end
  #   "
  #   assert grammar.parse_rule(:test, "a") == { result: "a" }
  # end
  
  def test_undefined_local_label_error
    assert_raise JetPEG::CompilationError do
      rule = JetPEG::Compiler.compile_rule "char:%missing"
      rule.parse "abc"
    end
  end
  
  # def test_left_recursion_handling
  #   grammar = JetPEG::Compiler.compile_grammar "
  #     rule expr
  #       add:( l:expr '+' r:num ) /
  #       sub:( l:expr '-' r:num ) /
  #       expr /
  #       @:num
  #     end
      
  #     rule num
  #       [0-9]+
  #     end
  #   "
  #   assert grammar.parse_rule(:expr, "1-2-3") == { sub: { l: { sub: { l: "1", r: "2" } }, r: "3" } }
  # end
  
end