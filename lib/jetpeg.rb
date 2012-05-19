require "jetpeg/compiler"

module JetPEG
  def self.load(filename)
    Compiler.compile_grammar IO.read(filename), filename
  end
end