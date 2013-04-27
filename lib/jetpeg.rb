require "jetpeg/compiler"

module JetPEG
  def self.load(filename, options = {})
    options[:filename] = filename
    Compiler.compile_grammar IO.read(filename), options
  end
end