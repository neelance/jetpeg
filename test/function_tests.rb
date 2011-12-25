require 'test/unit'
require "jetpeg"
JetPEG::Parser.default_options[:raise_on_failure] = false

class FunctionTests < Test::Unit::TestCase
  def test_error_function
    rule = JetPEG::Compiler.compile_rule "'a' $error['test'] 'b' 'c'"
    assert !rule.match("abc")
    assert rule.parser.failure_reason.is_a? JetPEG::ParsingError
    assert rule.parser.failure_reason.position == 1
    assert rule.parser.failure_reason.other_reasons == ["test"]
  end
  
  #def test_match_function
  #  rule = JetPEG::Compiler.compile_rule "%char:. $match[%char]"
  #  assert rule.match("aa")
  #  assert rule.match("bb")
  #  assert !rule.match("a")
  #  assert !rule.match("ab")
  #end
end