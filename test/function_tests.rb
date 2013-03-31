require 'test/unit'
require "jetpeg"
JetPEG::Parser.default_options[:raise_on_failure] = false
JetPEG::Parser.default_options[:track_malloc] = true

class FunctionTests < Test::Unit::TestCase
  def test_boolean_functions
    rule = JetPEG::Compiler.compile_rule "'a' v:$true 'bc' / 'd' v:$false 'ef'"
    assert rule.parse("abc") == { v: true }
    assert rule.parse("def") == { v: false }
    
    rule = JetPEG::Compiler.compile_rule "'a' ( 'b' v:$true )? 'c'"
    assert rule.parse("abc") == { v: true }
    assert rule.parse("ac") == {}
  end
  
  def test_error_function
    rule = JetPEG::Compiler.compile_rule "'a' $error['test'] 'bc'"
    assert !rule.parse("abc")
    assert rule.parser.failure_reason.is_a? JetPEG::ParsingError
    assert rule.parser.failure_reason.position == 1
    assert rule.parser.failure_reason.other_reasons == ["test"]
  end
  
  # def test_match_function
  #   rule = JetPEG::Compiler.compile_rule "%a:( . . ) $match[%a]"
  #   assert rule.parse("abab")
  #   assert rule.parse("cdcd")
  #   assert !rule.parse("a")
  #   assert !rule.parse("ab")
  #   assert !rule.parse("aba")
  #   assert !rule.parse("abaX")
  # end
  
  def test_modes
    grammar = JetPEG::Compiler.compile_grammar "
      rule test
        test2 $enter_mode['somemode', test2 $enter_mode['othermode', $leave_mode['somemode', test2]]]
      end
      rule test2
        !$in_mode['somemode'] 'a' / $in_mode['somemode'] 'b' 
      end
    "
    assert grammar.parse_rule(:test, "aba")
    assert !grammar.parse_rule(:test, "aaa")
    assert !grammar.parse_rule(:test, "bba")
    assert !grammar.parse_rule(:test, "abb")
  end
end