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
end