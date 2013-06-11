require "test/unit"
require "jetpeg"
JetPEG::Parser.default_options[:raise_on_failure] = false
JetPEG::Parser.default_options[:track_malloc] = true

class ExpressionsTests < Test::Unit::TestCase
  def test_string_terminal
    rule = JetPEG::Compiler.compile_rule '"abc"'
    assert rule.parse("abc")
    assert !rule.parse("ab")
    assert !rule.parse("Xbc")
    assert !rule.parse("abX")
    assert !rule.parse("abcX")
  end
  
  def test_character_class_terminal
    rule = JetPEG::Compiler.compile_rule '[b-df\\-h]'
    assert rule.parse("b")
    assert rule.parse("c")
    assert rule.parse("d")
    assert rule.parse("f")
    assert rule.parse("-")
    assert rule.parse("h")
    assert !rule.parse("a")
    assert !rule.parse("e")
    assert !rule.parse("g")
    
    rule = JetPEG::Compiler.compile_rule '[^a]'
    assert rule.parse("b")
    assert !rule.parse("a")
    
    rule = JetPEG::Compiler.compile_rule '[\\n]'
    assert rule.parse("\n")
    assert !rule.parse("n")
  end
  
  def test_any_character_terminal
    rule = JetPEG::Compiler.compile_rule '.'
    assert rule.parse("a")
    assert rule.parse("B")
    assert rule.parse("5")
    assert !rule.parse("")
    assert !rule.parse("99")
    
    rule = JetPEG::Compiler.compile_rule '.*'
    assert rule.parse("aaa")
  end
  
  def test_sequence
    rule = JetPEG::Compiler.compile_rule '"abc" "def"'
    assert rule.parse("abcdef")
    assert !rule.parse("abcde")
    assert !rule.parse("aXcdef")
    assert !rule.parse("abcdXf")
    assert !rule.parse("abcdefX")
  end
  
  def test_choice
    rule = JetPEG::Compiler.compile_rule '/ "abc" / "def"'
    assert rule.parse("abc")
    assert rule.parse("def")
    assert !rule.parse("ab")
    assert !rule.parse("aXc")
    assert !rule.parse("defX")
  end
  
  def test_optional
    rule = JetPEG::Compiler.compile_rule '"abc"? "def"'
    assert rule.parse("abcdef")
    assert rule.parse("def")
    assert !rule.parse("abc")
    assert !rule.parse("aXcdef")
    assert !rule.parse("abdef")
  end
  
  def test_zero_or_more
    rule = JetPEG::Compiler.compile_rule '"a"*'
    assert rule.parse("")
    assert rule.parse("a")
    assert rule.parse("aaaaa")
    assert !rule.parse("X")
    assert !rule.parse("aaaX")
  end
  
  def test_one_or_more
    rule = JetPEG::Compiler.compile_rule '"a"+'
    assert rule.parse("a")
    assert rule.parse("aaaaa")
    assert !rule.parse("")
    assert !rule.parse("X")
    assert !rule.parse("aaaX")
  end
  
  def test_until
    rule = JetPEG::Compiler.compile_rule '( "a" . )*->"ac"'
    assert rule.parse("ac")
    assert rule.parse("ababac")
    assert !rule.parse("")
    assert !rule.parse("ab")
    assert !rule.parse("abXbac")
    assert !rule.parse("ababacX")
    assert !rule.parse("ababacab")
    assert !rule.parse("ababacac")
  end
  
  def test_repetition_glue
    rule = JetPEG::Compiler.compile_rule '"a"*[ "," ]'
    assert rule.parse("")
    assert rule.parse("a")
    assert rule.parse("a,a,a")
    assert !rule.parse("aa")
    assert !rule.parse(",")
    assert !rule.parse("a,a,")
    assert !rule.parse(",a,a")
    assert !rule.parse("a,,a")
    
    rule = JetPEG::Compiler.compile_rule '"a"+[ "," ]'
    assert rule.parse("a")
    assert rule.parse("a,a,a")
    assert !rule.parse("aa")
    assert !rule.parse("")
    assert !rule.parse(",")
    assert !rule.parse("a,a,")
    assert !rule.parse(",a,a")
    assert !rule.parse("a,,a")
  end
  
  def test_parenthesized_expression
    rule = JetPEG::Compiler.compile_rule '( "a" ( ) "b" )? "c"'
    assert rule.parse("abc")
    assert rule.parse("c")
    assert !rule.parse("ac")
    assert !rule.parse("bc")
  end
  
  def test_positive_lookahead
    rule = JetPEG::Compiler.compile_rule '&"a" .'
    assert rule.parse("a")
    assert !rule.parse("")
    assert !rule.parse("X")
    assert !rule.parse("aX")
  end
  
  def test_negative_lookahead
    rule = JetPEG::Compiler.compile_rule '!"a" .'
    assert rule.parse("X")
    assert !rule.parse("")
    assert !rule.parse("a")
    assert !rule.parse("XX")
  end
  
  def test_rule_definition
    grammar = JetPEG::Compiler.compile_grammar '
      rule test
        "a"
      end
    '
    assert grammar.parse_rule(:test, "a")
    assert !grammar.parse_rule(:test, "X")
  end
  
  def test_rule_reference
    grammar = JetPEG::Compiler.compile_grammar '
      rule test
        a
      end
      rule a
        "b"
      end
    '
    assert grammar.parse_rule(:test, "b")
    assert !grammar.parse_rule(:test, "X")
    assert !grammar.parse_rule(:test, "a")
  end
  
  def test_recursive_rule
    grammar = JetPEG::Compiler.compile_grammar '
      rule test
        "(" test ")" / ( )
      end
    '
    assert grammar.parse_rule(:test, "")
    assert grammar.parse_rule(:test, "()")
    assert grammar.parse_rule(:test, "((()))")
    assert !grammar.parse_rule(:test, "()))")
    assert !grammar.parse_rule(:test, "((()")
  end
end