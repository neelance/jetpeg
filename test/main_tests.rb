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
end