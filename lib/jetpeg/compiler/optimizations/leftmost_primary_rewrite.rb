module JetPEG
  module Compiler
    class Choice
      def self.new(data)
        children = [data[:head]] + data[:tail]
        leftmost_primaries = children.map(&:get_leftmost_primary).uniq
        if leftmost_primaries.size == 1 and not leftmost_primaries.first.nil?
          local_label = Label.new expression: leftmost_primaries.first, is_local: true
          local_value = LocalValue.new({})
          local_value.local_label = local_label
          
          children.each { |child| child.replace_leftmost_primary local_value }
          return Sequence.new children: [local_label, super(children: children)]
        end
        
        super
      end
    end
  end
end
