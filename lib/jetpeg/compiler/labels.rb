module JetPEG
  module Compiler
    class Label < ParsingExpression
      leftmost_leaves :child

      block :_entry do
        @_end_input, @_has_return_value = build :child, @_start_input, :_failed
        
        if not @_has_return_value or @_data[:name] == "@"
          pop if @_has_return_value
          push_input_range @_start_input, @_end_input
        end

        if @_data[:is_local]
          locals_push i64(1)
        elsif @_data[:name] != "@"
          make_label string(:name)
        end
        
        @_has_return_value = !@_data[:is_local]
        br :_successful
      end
      
      def get_local_label(name, stack_index)
        if @data[:is_local]
          return stack_index if data[:name] == name
          return super name, stack_index + 1
        end
        super name, stack_index
      end
    end
    
    class LocalValue < ParsingExpression
      block :_entry do
        locals_load i64(@_current.get_local_label(@_data[:name], 0))
        @_has_return_value = true
        br :_successful
      end
    end
    
    class ObjectCreator < ParsingExpression
      leftmost_leaves :child

      block :_entry do
        @_end_input, @child_has_return_value = build :child, @_start_input, :_failed
        push_empty if not @child_has_return_value
        set_as_source if @_data[:data]
        build :data, @_start_input, :_failed if @_data[:data]
        make_object string(:class_name)
        @_has_return_value = true
        br :_successful
      end
    end
    
    class ValueCreator < ParsingExpression
      leftmost_leaves :child

      block :_entry do
        @_end_input, @child_has_return_value = build :child, @_start_input, :_failed
        push_empty if not @child_has_return_value
        make_value string(:code), string(@_filename), i64(@_data[:code].line)
        @_has_return_value = true
        br :_successful
      end
    end
  end
end