require 'test/unit'
require "jetpeg"
JetPEG::Parser.default_options[:raise_on_failure] = false

class MiscTests < Test::Unit::TestCase
  def test_root_switching
    grammar = JetPEG::Compiler.compile_grammar "
      rule test1
        'abc' / test2
      end
      rule test2
        'def'
      end
    "
    assert grammar[:test1].match("abc")
    assert grammar[:test2].match("def")
  end
  
  def test_failure_tracing
    rule = JetPEG::Compiler.compile_rule "'a' 'b' 'c'"
    assert !rule.match("aXc")
    assert rule.parser.failure_reason.is_a? JetPEG::ParsingError
    assert rule.parser.failure_reason.position == 1
    assert rule.parser.failure_reason.expectations == ["b"]
    
    rule = JetPEG::Compiler.compile_rule "'a' [b2-5] 'c'"
    assert !rule.match("aXc")
    assert rule.parser.failure_reason.is_a? JetPEG::ParsingError
    assert rule.parser.failure_reason.position == 1
    assert rule.parser.failure_reason.expectations == ["2-5", "b"]
  end
  
  def test_argument_errors
    assert_raise ArgumentError do
      JetPEG::Compiler.compile_rule true
    end
    
    assert_raise ArgumentError do
      rule = JetPEG::Compiler.compile_rule "'a'"
      rule.match true
    end
  end
  
  def test_compilation_errors
    assert_raise JetPEG::CompilationError do
      JetPEG::Compiler.compile_rule "missing_rule"
    end

    assert_raise JetPEG::CompilationError do
      JetPEG::Compiler.compile_rule "char:'a' 'b' char:'c'"
    end
    
    assert_raise JetPEG::CompilationError do
      JetPEG::Compiler.compile_rule "@:'a' 'b' char:'c'"
    end
    
    assert_raise JetPEG::CompilationError do
      JetPEG::Compiler.compile_rule "@:'a' 'b' @:'c'"
    end
    
    assert_raise JetPEG::CompilationError do
      JetPEG::Compiler.compile_rule "@:'a' 'b' / char:'c'"
    end
    
    assert_raise JetPEG::CompilationError do
      JetPEG::Compiler.compile_grammar "
        rule test
          '(' test ')' / char:'a'
        end
      "
    end
  end
  
  def test_metagrammar
    parser = JetPEG.load "lib/jetpeg/compiler/metagrammar.jetpeg"
    assert parser[:grammar].match(IO.read("lib/jetpeg/compiler/metagrammar.jetpeg"), output: :realized, class_scope: JetPEG::Compiler)
  end
end