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
    push_empty:       LLVM.Function([], LLVM.Void()),
    push_input_range: LLVM.Function([LLVM_STRING, LLVM_STRING], LLVM.Void()),
    push_boolean:     LLVM.Function([LLVM::Int1], LLVM.Void()),
    push_string:      LLVM.Function([LLVM_STRING], LLVM.Void()),
    push_array:       LLVM.Function([LLVM::Int1], LLVM.Void()),
    append_to_array:  LLVM.Function([], LLVM.Void()),
    make_label:       LLVM.Function([LLVM_STRING], LLVM.Void()),
    merge_labels:     LLVM.Function([LLVM::Int64], LLVM.Void()),
    make_value:       LLVM.Function([LLVM_STRING, LLVM_STRING, LLVM::Int64], LLVM.Void()),
    make_object:      LLVM.Function([LLVM_STRING], LLVM.Void()),
    pop:              LLVM.Function([], LLVM.Void()),
    locals_push:      LLVM.Function([], LLVM.Void()),
    locals_load:      LLVM.Function([LLVM::Int64], LLVM.Void()),
    locals_pop:       LLVM.Function([], LLVM.Void()),
    match:            LLVM.Function([LLVM_STRING], LLVM_STRING),
    set_as_source:    LLVM.Function([], LLVM.Void()),
    read_from_source: LLVM.Function([LLVM_STRING], LLVM.Void()),
    trace_enter:      LLVM.Function([LLVM_STRING], LLVM.Void()),
    trace_leave:      LLVM.Function([LLVM_STRING, LLVM::Int1], LLVM.Void()),
    trace_failure:    LLVM.Function([LLVM_STRING, LLVM_STRING, LLVM::Int1], LLVM.Void())
  }
  OUTPUT_FUNCTION_POINTERS = OUTPUT_INTERFACE_SIGNATURES.values.map { |fun_type| LLVM::Pointer(fun_type) }

  class Parser
    @@default_options = { filename: "grammar", raise_on_failure: true, class_scope: ::Object, bitcode_optimization: true, machine_code_optimization: 0, track_malloc: false }
    
    def self.default_options
      @@default_options
    end
    
    attr_reader :mod, :options, :execution_engine
    
    def initialize(mod, options = {})
      @mod = mod
      @options = options
      @options.merge!(@@default_options) { |key, oldval, newval| oldval }

      @execution_engine = nil
      @rules = nil
    end
    
    def parse(input)
      parse_rule @rules.values.first.rule_name, input
    end
    
    def parse_rule(rule_name, input)
      raise ArgumentError.new("Input must be a String.") if not input.is_a? String
      
      if @execution_engine.nil?
        @execution_engine = LLVM::JITCompiler.new @mod, @options[:machine_code_optimization]
        if @options[:bitcode_optimization]
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
      locals_stack = []
      temp_source = nil
      failure_position = 0
      failure_expectations = []
      failure_other_reasons = []

      new_checked_ffi_function = lambda { |name, parameter_types, return_type, &block|
        FFI::Function.new(return_type, parameter_types) { |*args|
          begin
            block.call(*args)
          rescue Exception => e
            puts e, e.backtrace
            exit!
          # ensure
          #   puts("#{name}(#{args.join ', '}): ".ljust(110) + output_stack.inspect) #if @rules
          end
        }
      }

      output_functions = [
        new_checked_ffi_function.call(:push_empty, [], :void) {
          output_stack << {}
        },
        new_checked_ffi_function.call(:push_input_range, [:pointer, :pointer], :void) { |from_ptr, to_ptr|
          range = (from_ptr.address - start_ptr.address)...(to_ptr.address - start_ptr.address)
          line = input[0, range.begin].count("\n")
          output_stack << StringWithPosition.new(input[range], range, line)
        },
        new_checked_ffi_function.call(:push_boolean, [:bool], :void) { |value|
          output_stack << value
        },
        new_checked_ffi_function.call(:push_string, [:string], :void) { |value|
          output_stack << value
        },
        new_checked_ffi_function.call(:push_array, [:bool], :void) { |append_current|
          array = []
          array << output_stack.pop if append_current
          output_stack << array
        },
        new_checked_ffi_function.call(:append_to_array, [], :void) {
          entry = output_stack.pop
          output_stack.last << entry
        },
        new_checked_ffi_function.call(:make_label, [:string], :void) { |name|
          value = output_stack.pop
          output_stack << { name.to_sym => value }
        },
        new_checked_ffi_function.call(:merge_labels, [:int64], :void) { |count|
          merged = output_stack.pop(count).select{ |v| v.is_a? Hash }.reduce(&:merge)
          output_stack << merged
        },
        new_checked_ffi_function.call(:make_value, [:string, :string, :int64], :void) { |code, filename, line|
          data = output_stack.pop
          scope = EvaluationScope.new data
          output_stack << scope.instance_eval(code, filename, line + 1)
        },
        new_checked_ffi_function.call(:make_object, [:string], :void) { |class_name|
          data = output_stack.pop
          object_class = class_name.split("::").map(&:to_sym).inject(@options[:class_scope]) { |scope, name| scope.const_get(name) }
          output_stack << object_class.new(data)
        },
        new_checked_ffi_function.call(:pop, [], :void) {
          output_stack.pop
        },
        new_checked_ffi_function.call(:locals_push, [], :void) {
          locals_stack.push output_stack.pop
        },
        new_checked_ffi_function.call(:locals_load, [:int64], :void) { |index|
          output_stack << locals_stack[-1 - index]
        },
        new_checked_ffi_function.call(:locals_pop, [], :void) { |count|
          locals_stack.pop
        },
        new_checked_ffi_function.call(:match, [:pointer], :pointer) { |input_ptr|
          expected = output_stack.pop
          if input[input_ptr.address - start_ptr.address, expected.length] == expected
            input_ptr + expected.length
          else
            LLVM_STRING.null
          end
        },
        new_checked_ffi_function.call(:set_as_source, [], :void) {
          temp_source = output_stack.pop
        },
        new_checked_ffi_function.call(:read_from_source, [:string], :void) { |name|
          output_stack << temp_source[name.to_sym]
        },
        new_checked_ffi_function.call(:trace_enter, [:string], :void) { |name|
          # only for tracing
        },
        new_checked_ffi_function.call(:trace_leave, [:string, :bool], :void) { |name, successful|
          # only for tracing
        },
        new_checked_ffi_function.call(:trace_failure, [:pointer, :string, :bool], :void) { |pos_ptr, reason, is_expectation|
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
        raise @failure_reason if @options[:raise_on_failure]
        return nil
      end
      success_value.dispose
      
      raise if output_stack.size > 1 or not locals_stack.empty?
      output = output_stack.last || {} 
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
    attr_reader :failure_reason, :mode_names
    
    def initialize(rules, options = {})
      super(nil, options)
      
      @rules = rules
      @rules.each_value { |rule| rule.parent = self }

      @rules.values.first.is_root = true
      build
    end
    
    def parse_rule(rule_name, input)
      if @mod.nil? or not @rules[rule_name].is_root
        @rules[rule_name].is_root = true
        build
      end
      
      super
    end
    
    def build
      if @execution_engine
        @execution_engine.dispose # disposes module, too
        @execution_engine = nil
      end
      
      @mod = LLVM::Module.new "Parser"
      @mode_names = @rules.values.map(&:all_mode_names).flatten.uniq
      @mode_struct = LLVM::Type.struct(([LLVM::Int1] * @mode_names.size), true, "mode_struct")
      
      malloc_counter = nil
      free_counter = nil
      if @options[:track_malloc]
        malloc_counter = mod.globals.add LLVM::Int64, :malloc_counter
        malloc_counter.initializer = LLVM::Int64.from_i(0)
        free_counter = mod.globals.add LLVM::Int64, :free_counter
        free_counter.initializer = LLVM::Int64.from_i(0)
      end

      @rules.each_value { |rule| rule.set_runtime @mod, @mode_struct }
      @rules.each_value { |rule| rule.match_function if rule.is_root }
      @mod.verify!
    end
    
    def parser
      self
    end
    
    def get_local_label(name, stack_index)
      return stack_index if name == "<left_recursion_value>"
      raise CompilationError.new("Undefined local value \"%#{name}\".")
    end
    
    def [](name)
      @rules[name]
    end
  end
  
end
