require "jetpeg/compiler"

module JetPEG
  def self.load(file)
    Compiler.compile_grammar IO.read("#{file}.jetpeg")
  end
end