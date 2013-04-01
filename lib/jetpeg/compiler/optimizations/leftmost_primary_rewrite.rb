module JetPEG
  module Compiler
    class Choice
      def self.new(data)
        return super if self != Choice # skip subclasses
        
        children = data[:children] || ([data[:head]] + data[:tail])
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
        if @children.first.is_primary
          @children.first
        else
          @children.first.get_leftmost_primary
        end
      end
      
      def replace_leftmost_primary(replacement)
        if @children.first.is_primary
          @children[0] = replacement
          replacement.parent = self
        else
          @children.first.replace_leftmost_primary replacement
        end
      end
    end
    
    module LeftmostPrimaryExpression
      def get_leftmost_primary
        if @expression.is_primary
          @expression
        else
          @expression.get_leftmost_primary
        end
      end
      
      def replace_leftmost_primary(replacement)
        if @expression.is_primary
          @expression = replacement
          replacement.parent = self
        else
          @expression.replace_leftmost_primary replacement
        end
      end
    end

    class Label
      include LeftmostPrimaryExpression
    end

    class ObjectCreator
      include LeftmostPrimaryExpression
    end

    class ValueCreator
      include LeftmostPrimaryExpression
    end
  end
end
