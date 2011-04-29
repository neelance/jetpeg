require "jetpeg/compiler"

module JetPEG
  def self.load(file)
    code = Compiler.compile IO.read("#{file}.jetpeg")
    Object.class_eval code
  end
end