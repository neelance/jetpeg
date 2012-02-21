module JetPEG
  module Compiler
    class ParsingExpression
      attr_accessor :parent, :name, :local_label_source
      attr_reader :recursive_expressions
      
      def initialize
        @name = nil
        @children = []
        @return_type = :pending
        @return_type_recursion = false
        @bare_rule_function = nil
        @traced_rule_function = nil
        @recursive_expressions = []
        @local_label_source = nil
      end
      
      def children=(array)
        @children = array
        @children.each { |child| child.parent = self }
      end
      
      def parser
        @parent.parser
      end
      
      def metagrammar?
        parser == JetPEG::Compiler.metagrammar_parser
      end
      
      def rule
        @name ? self : parent.rule
      end
      
      def return_type
        if @return_type == :pending
          raise Recursion.new(self) if @return_type_recursion
          begin
            @return_type_recursion = true
            @return_type = create_return_type
          rescue Recursion => recursion
            raise recursion if not recursion.expression.equal? self
            @return_type = nil
          ensure
            @return_type_recursion = false
          end
          raise CompilationError.new("Unlabeled recursion mixed with other labels.", rule) if @return_type.nil? and not create_return_type.nil?
        end
        @return_type
      end
      
      def create_return_type
        nil
      end
      
      def realize_recursive_return_types
        @recursive_expressions.each(&:return_type)
      end
      
      def get_local_label(name)
        @local_label_source ||= parent
        @local_label_source.get_local_label name
      end
      
      def has_local_value?
        false
      end
      
      def free_local_value(builder)
        # nothing to do
      end
      
      def get_leftmost_primary
        nil
      end
      
      def replace_leftmost_primary(replacement)
        raise
      end
      
      def build_allocas(builder)
        @children.each { |child| child.build_allocas builder }
      end
      
      def mod=(mod)
        @mod = mod
        @bare_rule_function = nil
        @traced_rule_function = nil
      end
      
      def rule_function(traced)
        return @bare_rule_function if not traced and @bare_rule_function
        return @traced_rule_function if traced and @traced_rule_function
        
        params = []
        params << LLVM_STRING
        params << LLVM::Pointer(return_type.llvm_type) unless return_type.nil?
        function = @mod.functions.add @name, params, LLVM_STRING
        
        if traced
          @traced_rule_function = function
        else
          @bare_rule_function = function
        end
        
        builder = Builder.new
        builder.parser = parser
        builder.traced = traced
        
        entry = function.basic_blocks.append "entry"
        builder.position_at_end entry
        build_allocas builder
        
        failed_block = builder.create_block "failed"
        end_result = build builder, function.params[0], failed_block
        
        builder.store end_result.return_value, function.params[1] if return_type
        builder.ret end_result.input
        
        builder.position_at_end failed_block
        builder.ret LLVM_STRING.null_pointer
        
        builder.dispose
        
        function
      end
      
      def match(input, options = {})
        parser.match_rule self, input, options
      end
      
      def free_value(value)
        return if return_type.nil?
        parser.execution_engine.run_function parser.free_value_functions[return_type.llvm_type], value
      end
          
      def eql?(other)
        self == other
      end
      
      def hash
        0 # no hash used for Array.uniq, always eql?
      end
    end
    
    class Primary < ParsingExpression
    end
  end
end