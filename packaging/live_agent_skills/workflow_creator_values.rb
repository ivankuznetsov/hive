# frozen_string_literal: true

module HiveLiveAgentProof
  module WorkflowCreator
    module Values
      class Error < StandardError; end
      CAPTURE_FAILURE = Error.new("workflow-creator value cannot be captured")
      MARSHAL_FAILURE = TypeError.new("workflow-creator snapshots cannot be marshaled")
      failure_protocol = %i[backtrace cause exception initialize_clone initialize_copy message set_backtrace to_s]
      [ CAPTURE_FAILURE, MARSHAL_FAILURE ].each do |failure|
        failure_protocol.each { |name| failure.singleton_class.alias_method(name, name) }
        failure.freeze
      end
      INVOKE = :__workflow_creator_values_invoke__
      MAX_DEPTH = 64
      MAX_NODES = 8_192
      MAX_SOURCE_BYTES = 262_144
      MAX_CANONICAL_BYTES = 1_048_576
      MAX_WORK_UNITS = 4_194_304
      MAX_INTEGER_BITS = 4_096
      NODES = 0
      SOURCE_BYTES = 1
      WORK_UNITS = 2
      ACTIVE = 3
      def self.seal(operation)
        singleton = operation.singleton_class
        singleton.alias_method(INVOKE, :bind_call)
        singleton.__send__(:private, INVOKE)
        singleton.alias_method(:send, :__send__)
        operation.freeze
      end
      OBJECT_CLASS = seal(Object.instance_method(:class))
      RAISE = seal(Kernel.instance_method(:raise))
      OBJECT_CLONE = seal(Object.instance_method(:clone))
      MODULE_CASE = seal(Module.instance_method(:===))
      FAILURE_BASE = StandardError
      OBJECT_FREEZE = seal(Object.instance_method(:freeze))
      OBJECT_SET_IVAR = seal(Object.instance_method(:instance_variable_set))
      OBJECT_EQUAL = seal(BasicObject.instance_method(:equal?))
      CLASS_ALLOCATE = seal(Class.instance_method(:allocate))
      HASH_EACH_PAIR = seal(Hash.instance_method(:each_pair))
      HASH_LENGTH = seal(Hash.instance_method(:length))
      HASH_SET = seal(Hash.instance_method(:[]=))
      ARRAY_EACH = seal(Array.instance_method(:each))
      ARRAY_INDEX = seal(Array.instance_method(:index))
      ARRAY_LENGTH = seal(Array.instance_method(:length))
      ARRAY_GET = seal(Array.instance_method(:[]))
      ARRAY_SET = seal(Array.instance_method(:[]=))
      ARRAY_PUSH = seal(Array.instance_method(:<<))
      ARRAY_POP = seal(Array.instance_method(:pop))
      ARRAY_SORT = seal(Array.instance_method(:sort!))
      STRING_DUP = seal(String.instance_method(:dup))
      STRING_ENCODING = seal(String.instance_method(:encoding))
      STRING_BYTESIZE = seal(String.instance_method(:bytesize))
      STRING_ENCODE = seal(String.instance_method(:encode))
      STRING_EACH_BYTE = seal(String.instance_method(:each_byte))
      STRING_BYTESLICE = seal(String.instance_method(:byteslice))
      STRING_APPEND = seal(String.instance_method(:<<))
      STRING_COMPARE = seal(String.instance_method(:<=>))
      STRING_FORMAT = seal(String.instance_method(:%))
      INTEGER_ADD = seal(Integer.instance_method(:+))
      INTEGER_MULTIPLY = seal(Integer.instance_method(:*))
      INTEGER_GREATER = seal(Integer.instance_method(:>))
      INTEGER_EQUAL = seal(Integer.instance_method(:==))
      INTEGER_BITS = seal(Integer.instance_method(:bit_length))
      INTEGER_TO_S = seal(Integer.instance_method(:to_s))
      FLOAT_FINITE = seal(Float.instance_method(:finite?))
      FLOAT_TO_S = seal(Float.instance_method(:to_s))
      ENCODING_DUMMY = seal(Encoding.instance_method(:dummy?))
      UTF8 = Encoding::UTF_8
      UTF16 = Encoding::UTF_16LE
      BINARY = Encoding::BINARY
      FAILURE_MATCHER = Module.new do
        def self.===(error) = MODULE_CASE.send(INVOKE, FAILURE_BASE, error)
      end.freeze
      @snapshot_class = Class.new do
        def value = @value
        def canonical_bytes = @canonical_bytes
        def inspect = "#<HiveLiveAgentProof::WorkflowCreator::Values snapshot>"
        def marshal_dump
          failure = OBJECT_CLONE.send(INVOKE, MARSHAL_FAILURE, freeze: false)
          RAISE.send(INVOKE, self, failure, cause: nil)
        end
        def marshal_load(_payload)
          failure = OBJECT_CLONE.send(INVOKE, MARSHAL_FAILURE, freeze: false)
          RAISE.send(INVOKE, self, failure, cause: nil)
        end
        private :marshal_dump, :marshal_load
        undef_method :dup, :clone, :instance_variable_set, :remove_instance_variable
      end
      @snapshot_class.singleton_class.class_eval do
        private :new, :allocate
        undef_method :dup, :clone
      end
      def self.capture(input)
        state = [ 0, 0, 0, [] ]
        charge!(state, 1)
        owned, fragment = import_value(input, state, 0)
        canonical = STRING_DUP.send(INVOKE, "")
        append!(state, canonical, fragment)
        append!(state, canonical, "\n")
        OBJECT_FREEZE.send(INVOKE, canonical)
        snapshot = CLASS_ALLOCATE.send(INVOKE, @snapshot_class)
        OBJECT_SET_IVAR.send(INVOKE, snapshot, :@value, owned)
        OBJECT_SET_IVAR.send(INVOKE, snapshot, :@canonical_bytes, canonical)
        OBJECT_FREEZE.send(INVOKE, snapshot)
      rescue FAILURE_MATCHER
        fail_capture!
      end
      def self.fail_capture!
        failure = OBJECT_CLONE.send(INVOKE, CAPTURE_FAILURE, freeze: false)
        RAISE.send(INVOKE, self, failure, cause: nil)
      end
      def self.import_value(value, state, depth)
        fail_capture! if INTEGER_GREATER.send(INVOKE, depth, MAX_DEPTH)
        nodes = INTEGER_ADD.send(INVOKE, ARRAY_GET.send(INVOKE, state, NODES), 1)
        fail_capture! if INTEGER_GREATER.send(INVOKE, nodes, MAX_NODES)
        ARRAY_SET.send(INVOKE, state, NODES, nodes)
        klass = OBJECT_CLASS.send(INVOKE, value)
        if OBJECT_EQUAL.send(INVOKE, klass, Hash)
          import_hash(value, state, depth)
        elsif OBJECT_EQUAL.send(INVOKE, klass, Array)
          import_array(value, state, depth)
        elsif OBJECT_EQUAL.send(INVOKE, klass, String)
          import_string(value, state)
        elsif OBJECT_EQUAL.send(INVOKE, klass, Integer)
          import_integer(value, state)
        elsif OBJECT_EQUAL.send(INVOKE, klass, Float)
          import_float(value, state)
        elsif OBJECT_EQUAL.send(INVOKE, klass, TrueClass)
          [ value, "true" ]
        elsif OBJECT_EQUAL.send(INVOKE, klass, FalseClass)
          [ value, "false" ]
        elsif OBJECT_EQUAL.send(INVOKE, klass, NilClass)
          [ value, "null" ]
        else
          fail_capture!
        end
      end
      def self.import_hash(value, state, depth)
        active = ARRAY_GET.send(INVOKE, state, ACTIVE)
        duplicate = ARRAY_INDEX.send(INVOKE, active) { |item| OBJECT_EQUAL.send(INVOKE, item, value) }
        fail_capture! if duplicate
        length = HASH_LENGTH.send(INVOKE, value)
        minimum = INTEGER_ADD.send(INVOKE, ARRAY_GET.send(INVOKE, state, NODES),
                                      INTEGER_MULTIPLY.send(INVOKE, length, 2))
        fail_capture! if INTEGER_GREATER.send(INVOKE, minimum, MAX_NODES)
        ARRAY_PUSH.send(INVOKE, active, value)
        begin
          entries = []
          owned = {}
          HASH_EACH_PAIR.send(INVOKE, value) do |raw_key, raw_value|
            import_hash_entry(raw_key, raw_value, state, depth, entries, owned)
          end
          charge!(state, INTEGER_MULTIPLY.send(INVOKE, length, INTEGER_BITS.send(INVOKE, length)))
          ARRAY_SORT.send(INVOKE, entries) do |left, right|
            STRING_COMPARE.send(INVOKE, ARRAY_GET.send(INVOKE, left, 0),
                                    ARRAY_GET.send(INVOKE, right, 0))
          end
          build_collection(owned, entries, state, "{", "}")
        ensure
          ARRAY_POP.send(INVOKE, active)
        end
      end
      def self.import_hash_entry(raw_key, raw_value, state, depth, entries, owned)
        key_class = OBJECT_CLASS.send(INVOKE, raw_key)
        fail_capture! unless OBJECT_EQUAL.send(INVOKE, key_class, String)
        charge!(state, 3)
        key, key_json = import_value(raw_key, state, INTEGER_ADD.send(INVOKE, depth, 1))
        nested, nested_json = import_value(raw_value, state, INTEGER_ADD.send(INVOKE, depth, 1))
        charge!(state, 1)
        prior_length = HASH_LENGTH.send(INVOKE, owned)
        HASH_SET.send(INVOKE, owned, key, nested)
        if INTEGER_EQUAL.send(INVOKE, HASH_LENGTH.send(INVOKE, owned), prior_length)
          fail_capture!
        end
        ARRAY_PUSH.send(INVOKE, entries, [ key, nested, [ key_json, ":", nested_json ] ])
      end
      def self.import_array(value, state, depth)
        active = ARRAY_GET.send(INVOKE, state, ACTIVE)
        duplicate = ARRAY_INDEX.send(INVOKE, active) { |item| OBJECT_EQUAL.send(INVOKE, item, value) }
        fail_capture! if duplicate
        length = ARRAY_LENGTH.send(INVOKE, value)
        minimum = INTEGER_ADD.send(INVOKE, ARRAY_GET.send(INVOKE, state, NODES), length)
        fail_capture! if INTEGER_GREATER.send(INVOKE, minimum, MAX_NODES)
        ARRAY_PUSH.send(INVOKE, active, value)
        begin
          entries = []
          owned = []
          ARRAY_EACH.send(INVOKE, value) do |raw_value|
            charge!(state, 2)
            nested, nested_json = import_value(raw_value, state, INTEGER_ADD.send(INVOKE, depth, 1))
            ARRAY_PUSH.send(INVOKE, entries, [ nil, nested, [ nested_json ] ])
            ARRAY_PUSH.send(INVOKE, owned, nested)
          end
          build_collection(owned, entries, state, "[", "]")
        ensure
          ARRAY_POP.send(INVOKE, active)
        end
      end
      def self.build_collection(owned, entries, state, opening, closing)
        output = STRING_DUP.send(INVOKE, "")
        append!(state, output, opening)
        separator = ""
        ARRAY_EACH.send(INVOKE, entries) do |entry|
          append!(state, output, separator)
          fragments = ARRAY_GET.send(INVOKE, entry, 2)
          ARRAY_EACH.send(INVOKE, fragments) { |fragment| append!(state, output, fragment) }
          separator = ","
        end
        append!(state, output, closing)
        [ OBJECT_FREEZE.send(INVOKE, owned), output ]
      end
      def self.import_string(value, state)
        encoding = STRING_ENCODING.send(INVOKE, value)
        fail_capture! if ENCODING_DUMMY.send(INVOKE, encoding)
        fail_capture! if OBJECT_EQUAL.send(INVOKE, encoding, BINARY)
        bytes = STRING_BYTESIZE.send(INVOKE, value)
        source = INTEGER_ADD.send(INVOKE, ARRAY_GET.send(INVOKE, state, SOURCE_BYTES), bytes)
        fail_capture! if INTEGER_GREATER.send(INVOKE, source, MAX_SOURCE_BYTES)
        ARRAY_SET.send(INVOKE, state, SOURCE_BYTES, source)
        charge!(state, bytes)
        validated = STRING_ENCODE.send(INVOKE, value, UTF16)
        owned = STRING_ENCODE.send(INVOKE, validated, UTF8)
        output = STRING_DUP.send(INVOKE, "")
        append!(state, output, '"')
        index = 0
        STRING_EACH_BYTE.send(INVOKE, owned) do |byte|
          append!(state, output, escape_byte(owned, byte, index))
          index = INTEGER_ADD.send(INVOKE, index, 1)
        end
        append!(state, output, '"')
        [ OBJECT_FREEZE.send(INVOKE, owned), output ]
      end
      def self.import_integer(value, state)
        bits = INTEGER_BITS.send(INVOKE, value)
        fail_capture! if INTEGER_GREATER.send(INVOKE, bits, MAX_INTEGER_BITS)
        charge!(state, bits)
        [ value, INTEGER_TO_S.send(INVOKE, value) ]
      end
      def self.import_float(value, state)
        fail_capture! unless FLOAT_FINITE.send(INVOKE, value)
        charge!(state, 64)
        [ value, FLOAT_TO_S.send(INVOKE, value) ]
      end
      def self.escape_byte(value, byte, index)
        if INTEGER_EQUAL.send(INVOKE, byte, 34)
          '\\"'
        elsif INTEGER_EQUAL.send(INVOKE, byte, 92)
          "\\\\"
        elsif INTEGER_EQUAL.send(INVOKE, byte, 8)
          "\\b"
        elsif INTEGER_EQUAL.send(INVOKE, byte, 12)
          "\\f"
        elsif INTEGER_EQUAL.send(INVOKE, byte, 10)
          "\\n"
        elsif INTEGER_EQUAL.send(INVOKE, byte, 13)
          "\\r"
        elsif INTEGER_EQUAL.send(INVOKE, byte, 9)
          "\\t"
        elsif INTEGER_GREATER.send(INVOKE, 32, byte)
          STRING_FORMAT.send(INVOKE, "\\u00%02x", byte)
        else
          STRING_BYTESLICE.send(INVOKE, value, index, 1)
        end
      end
      def self.append!(state, output, fragment)
        bytes = STRING_BYTESIZE.send(INVOKE, fragment)
        charge!(state, bytes)
        size = INTEGER_ADD.send(INVOKE, STRING_BYTESIZE.send(INVOKE, output), bytes)
        if INTEGER_GREATER.send(INVOKE, size, MAX_CANONICAL_BYTES)
          fail_capture!
        end
        STRING_APPEND.send(INVOKE, output, fragment)
      end
      def self.charge!(state, amount)
        units = INTEGER_ADD.send(INVOKE, ARRAY_GET.send(INVOKE, state, WORK_UNITS), amount)
        fail_capture! if INTEGER_GREATER.send(INVOKE, units, MAX_WORK_UNITS)
        ARRAY_SET.send(INVOKE, state, WORK_UNITS, units)
      end
      private_class_method :seal, :import_value, :import_hash_entry, :build_collection, :import_string, :import_integer,
                           :import_float, :import_hash, :import_array, :escape_byte, :append!, :charge!, :fail_capture!
      private_constant :CAPTURE_FAILURE, :MARSHAL_FAILURE, :INVOKE,
                       :MAX_DEPTH, :MAX_NODES, :MAX_SOURCE_BYTES, :MAX_CANONICAL_BYTES, :MAX_WORK_UNITS,
                       :MAX_INTEGER_BITS, :NODES, :SOURCE_BYTES, :WORK_UNITS, :ACTIVE, :OBJECT_CLASS, :OBJECT_FREEZE,
                       :OBJECT_SET_IVAR, :OBJECT_EQUAL, :CLASS_ALLOCATE, :HASH_EACH_PAIR, :HASH_LENGTH, :HASH_SET,
                       :ARRAY_EACH, :ARRAY_INDEX, :ARRAY_LENGTH, :ARRAY_GET, :ARRAY_SET, :ARRAY_PUSH, :ARRAY_POP,
                       :ARRAY_SORT, :STRING_DUP, :STRING_ENCODING, :STRING_BYTESIZE, :STRING_ENCODE, :STRING_EACH_BYTE,
                       :STRING_BYTESLICE, :STRING_APPEND, :STRING_COMPARE, :STRING_FORMAT, :INTEGER_ADD,
                       :INTEGER_MULTIPLY, :INTEGER_GREATER, :INTEGER_EQUAL, :INTEGER_BITS, :INTEGER_TO_S, :FLOAT_FINITE,
                       :RAISE, :OBJECT_CLONE, :MODULE_CASE, :FAILURE_BASE, :FAILURE_MATCHER, :FLOAT_TO_S,
                       :ENCODING_DUMMY, :UTF8, :UTF16, :BINARY
      OBJECT_FREEZE.send(INVOKE, @snapshot_class)
      OBJECT_FREEZE.send(INVOKE, Error)
      OBJECT_FREEZE.send(INVOKE, self)
    end
  end
end
