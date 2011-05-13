require 'test/unit'
require "jetpeg"

class ExpressionsTests < Test::Unit::TestCase
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
end