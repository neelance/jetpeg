require "jetpeg/compiler"

module JetPEG
  def self.load(file)
    code = Compiler.compile IO.read("#{file}.jetpeg")
    # File.open("#{file}.compiled.rb", "w") { |io| io.write code }
    Object.class_eval code
  end
end