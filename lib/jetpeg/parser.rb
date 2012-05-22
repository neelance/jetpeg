verbose = $VERBOSE
$VERBOSE = false
require 'llvm/core'
require 'llvm/execution_engine'
require 'llvm/transforms/scalar'
require 'llvm/transforms/ipo'
$VERBOSE = verbose

LLVM.init_x86

module JetPEG
  
  class StringWithPosition < String
    attr_reader :range, :line
    
    def initialize(content, range, line)
      super content
      @range = range
      @line = line
    end
  end
  
  class ParsingError < RuntimeError
    attr_reader :input, :position, :expectations, :other_reasons
    
    def initialize(input, position, expectations, other_reasons)
      @input = input
      @position = position
      @expectations = expectations.uniq.sort
      @other_reasons = other_reasons.uniq.sort
    end
    
    def to_s
      before = @input[0...@position]
      line = before.count("\n") + 1
      column = before.size - (before.rindex("\n") || 0)
      
      reasons = @other_reasons.dup
      reasons << "Expected one of #{@expectations.join(", ")}" unless @expectations.empty?
      
      "At line #{line}, column #{column} (byte #{position}, after #{before[(before.size > 20 ? -20 : 0)..-1].inspect}): #{reasons.join(' / ')}."
    end
  end
  
  class EvaluationScope
    def initialize(data)
      @data = data
      if data.is_a? Hash
        data.each do |key, value|
          instance_variable_set "@#{key}", value
        end
      end
    end
  end
  
  OUTPUT_INTERFACE_SIGNATURES = {
    new_nil:         LLVM.Function([], LLVM.Void()),
    new_input_range: LLVM.Function([LLVM_STRING, LLVM_STRING], LLVM.Void()),
    new_boolean:     LLVM.Function([LLVM::Int1], LLVM.Void()),
    make_label:      LLVM.Function([LLVM_STRING], LLVM.Void()),
    merge_labels:    LLVM.Function([LLVM::Int64], LLVM.Void()),
    make_array:      LLVM.Function([], LLVM.Void()),
    make_object:     LLVM.Function([LLVM_STRING], LLVM.Void()),
    make_value:      LLVM.Function([LLVM_STRING, LLVM_STRING, LLVM::Int64], LLVM.Void()),
    add_failure:     LLVM.Function([LLVM_STRING, LLVM_STRING, LLVM::Int1], LLVM.Void())
  }
  OUTPUT_FUNCTION_POINTERS = OUTPUT_INTERFACE_SIGNATURES.values.map { |fun_type| LLVM::Pointer(fun_type) }
  
  class Parser
    @@default_options = { raise_on_failure: true, class_scope: ::Object, bitcode_optimization: true, machine_code_optimization: 0, track_malloc: false }
    
    def self.default_options
      @@default_options
    end
    
    attr_reader :mod, :execution_engine
    
    def initialize(mod)
      @mod = mod
      @execution_engine = nil
    end
    
    def parse(input, options = {})
      parse_rule @rules.values.first.rule_name, input, options
    end
    
    def parse_rule(rule_name, input, options = {})
      raise ArgumentError.new("Input must be a String.") if not input.is_a? String
      options.merge!(@@default_options) { |key, oldval, newval| oldval }
      
      if @execution_engine.nil?
        @execution_engine = LLVM::JITCompiler.new @mod, options[:machine_code_optimization]
        if options[:bitcode_optimization]
          pass_manager = LLVM::PassManager.new @execution_engine # TODO tweak passes
          pass_manager.inline!
          pass_manager.mem2reg! # alternative: pass_manager.scalarrepl!
          pass_manager.instcombine!
          pass_manager.reassociate!
          pass_manager.gvn!
          pass_manager.simplifycfg!
          pass_manager.run @mod
        end
      end
      
      start_ptr = FFI::MemoryPointer.from_string input
      end_ptr = start_ptr + input.size
      
      output_stack = []
      failure_position = 0
      failure_expectations = []
      failure_other_reasons = []
      output_functions = [
        FFI::Function.new(:void, []) { # 0: new_nil
          output_stack << nil
        },
        FFI::Function.new(:void, [:pointer, :pointer]) { |from_ptr, to_ptr| # 1: new_input_range
          range = (from_ptr.address - start_ptr.address)...(to_ptr.address - start_ptr.address)
          line = input[0, range.begin].count("\n")
          output_stack << StringWithPosition.new(input[range], range, line)
        },
        FFI::Function.new(:void, [:bool]) { |value| # 2: new_boolean
          output_stack << value
        },
        FFI::Function.new(:void, [:string]) { |name| # 3: make_label
          value = output_stack.pop
          output_stack << { name.to_sym => value }
        },
        FFI::Function.new(:void, [:int64]) { |count| # 4: merge_labels
          merged = output_stack.pop(count).compact.reduce(&:merge)
          output_stack << merged
        },
        FFI::Function.new(:void, []) { # 5: make_array
          data = output_stack.pop
          array = []
          until data.nil?
            array.unshift data[:value]
            data = data[:previous]
          end
          output_stack << array
        },
        FFI::Function.new(:void, [:string]) { |class_name| # 6: make_object
          data = output_stack.pop
          object_class = class_name.split("::").map(&:to_sym).inject(options[:class_scope]) { |scope, name| scope.const_get(name) }
          output_stack << object_class.new(data)
        },
        FFI::Function.new(:void, [:string, :string, :int64]) { |code, filename, line| # 7: make_value
          data = output_stack.pop
          scope = EvaluationScope.new data
          output_stack << scope.instance_eval(code, filename, line + 1)
        },
        FFI::Function.new(:void, [:pointer, :string, :bool]) { |pos_ptr, reason, is_expectation| # 8: add_failure
          position = pos_ptr.address - start_ptr.address
          if position > failure_position
            failure_position = position
            failure_expectations.clear
            failure_other_reasons.clear
          end
          if position == failure_position
            failure_expectations << reason if is_expectation
            failure_other_reasons << reason if !is_expectation
          end
        }
      ]
      
      success_value = @execution_engine.run_function @mod.functions["#{rule_name}_match"], start_ptr, end_ptr, *output_functions
      if not success_value.to_b
        success_value.dispose
        check_malloc_counter
        @failure_reason = ParsingError.new input, failure_position, failure_expectations, failure_other_reasons
        raise @failure_reason if options[:raise_on_failure]
        return nil
      end
      success_value.dispose
      
      output = output_stack.first || {} 
      check_malloc_counter
      
      output
    end
    
    def stats
      block_counts = @mod.functions.map { |f| f.basic_blocks.size }
      instruction_counts = @mod.functions.map { |f| f.basic_blocks.map { |b| b.instructions.to_a.size } }
      info = "#{@mod.functions.to_a.size} functions / #{block_counts.reduce(:+)} blocks / #{instruction_counts.flatten.reduce(:+)} instructions"
      if @mod.globals[:malloc_counter]
        malloc_count = @execution_engine.pointer_to_global(@mod.globals[:malloc_counter]).read_int64
        free_count = @execution_engine.pointer_to_global(@mod.globals[:free_counter]).read_int64
        info << "\n#{malloc_count} calls of malloc / #{free_count} calls of free"
      end
      info
    end
    
    def check_malloc_counter
      return if @mod.globals[:malloc_counter].nil?
      malloc_count = @execution_engine.pointer_to_global(@mod.globals[:malloc_counter]).read_int64
      free_count = @execution_engine.pointer_to_global(@mod.globals[:free_counter]).read_int64
      raise "Internal error: Memory leak (#{malloc_count - free_count})." if malloc_count != free_count
    end
  end
  
  class JitParser < Parser
    attr_reader :failure_reason, :filename, :value_types, :mode_names
    attr_accessor :root_rules
    
    def initialize(rules, filename = "grammar")
      super(nil)
      
      @rules = rules
      @rules.each_value { |rule| rule.parent = self }
      @filename = filename

      @root_rules = [@rules.values.first.rule_name]
      @value_types = [InputRangeValueType::INSTANCE]
      
      @rules.each_value(&:return_type) # calculate all return types
      @value_types.each { |type| type.realize if type.is_a? PointerValueType }
    end
    
    def parse_rule(rule_name, input, options = {})
      if @mod.nil? or not @root_rules.include?(rule_name)
        @root_rules << rule_name
        build options
      end
      
      super
    end
    
    def build(options = {})
      options.merge!(@@default_options) { |key, oldval, newval| oldval }

      if @execution_engine
        @execution_engine.dispose # disposes module, too
        @execution_engine = nil
      end
      
      @mod = LLVM::Module.new "Parser"
      @mode_names = @rules.values.map(&:all_mode_names).flatten.uniq
      @mode_struct = LLVM::Type.struct(([LLVM::Int1] * @mode_names.size), true, "mode_struct")
      
      builder = Compiler::Builder.new
      builder.init @mod, options[:track_malloc]
      @rules.each_value { |rule| rule.create_functions @mod, @root_rules.include?(rule.rule_name), @mode_struct }
      @value_types.each { |type| type.create_functions @mod }
      @rules.each_value { |rule| rule.build_functions builder, @root_rules.include?(rule.rule_name), @mode_struct }
      @value_types.each { |type| type.build_functions builder }
      builder.dispose
      
      @mod.verify!
    end
    
    def parser
      self
    end
    
    def get_local_label(name)
      nil
    end
    
    def [](name)
      @rules[name]
    end
  end
  
end
