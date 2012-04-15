module JetPEG
  module Compiler
    class Choice
      def self.new(data)
        return super if self != Choice # skip subclasses
        
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
    
    class ParsingExpression
      def get_leftmost_primary
        nil
      end
      
      def replace_leftmost_primary(replacement)
        raise
      end
    end
    
    class Sequence
      def get_leftmost_primary
        if @children.first.is_a? Primary
          @children.first
        else
          @children.first.get_leftmost_primary
        end
      end
      
      def replace_leftmost_primary(replacement)
        if @children.first.is_a? Primary
          @children[0] = replacement
          replacement.parent = self
        else
          @children.first.replace_leftmost_primary replacement
        end
      end
    end
    
    class Label
      def get_leftmost_primary
        if @expression.is_a? Primary
          @expression
        else
          @expression.get_leftmost_primary
        end
      end
      
      def replace_leftmost_primary(replacement)
        if @expression.is_a? Primary
          @expression = replacement
          replacement.parent = self
        else
          @expression.replace_leftmost_primary replacement
        end
      end
    end
  end
end
