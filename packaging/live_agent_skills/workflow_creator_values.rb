require "json"
module HiveLiveAgentProof
  module WorkflowCreator
    module Values
      class Error < StandardError; end
      Snapshot = Data.define(:value, :canonical_bytes) do
        private def marshal_dump = raise(TypeError, "workflow-creator snapshots cannot be marshaled")
      end
      Snapshot.singleton_class.send(:private, :new, :[], :allocate)
      Snapshot.send(:private, :with)
      MAX_DEPTH, MAX_NODES, MAX_INTEGER_BITS = 64, 8_192, 4_096
      MAX_INPUT_BYTES, MAX_PROJECTED_BYTES, MAX_ALLOCATION_BYTES = 262_144, 1_048_576, 4_194_304
      SEAL = lambda do |operation, invocation|
        operation.singleton_class.send(:alias_method, :__invoke__, invocation)
        operation.freeze
      end.freeze
      OBJECT_CLASS, OBJECT_FREEZE = %i[class freeze].map { SEAL.call(Object.instance_method(_1), :bind_call) }
      OBJECT_EQUAL, OBJECT_ID = %i[equal? __id__].map { SEAL.call(BasicObject.instance_method(_1), :bind_call) }
      CLASS_ALLOCATE, PROC_CALL, DATA_INITIALIZE =
        [ [ Class, :allocate ], [ Proc, :call ], [ Data, :initialize ] ].map { |owner, name| SEAL.call(owner.instance_method(name), :bind_call) }
      HASH_EACH_PAIR, HASH_KEY, HASH_SET, HASH_DELETE, HASH_LENGTH =
        %i[each_pair key? []= delete length].map { SEAL.call(Hash.instance_method(_1), :bind_call) }
      ARRAY_EACH, ARRAY_GET, ARRAY_SET, ARRAY_PUSH, ARRAY_INDEX, ARRAY_LENGTH, ARRAY_SORT =
        %i[each [] []= << index length sort!].map { SEAL.call(Array.instance_method(_1), :bind_call) }
      STRING_INITIALIZE, STRING_ENCODING, STRING_BYTESIZE, STRING_ENCODE, STRING_EACH_BYTE, STRING_APPEND, STRING_COMPARE =
        %i[initialize encoding bytesize encode each_byte << <=>].map { SEAL.call(String.instance_method(_1), :bind_call) }
      INTEGER_ADD, INTEGER_SUBTRACT, INTEGER_MULTIPLY, INTEGER_GREATER, INTEGER_ZERO, INTEGER_BITS, INTEGER_TO_S =
        %i[+ - * > zero? bit_length to_s].map { SEAL.call(Integer.instance_method(_1), :bind_call) }
      JSON_GENERATE = SEAL.call(JSON::State.method(:_generate_no_fallback), :call)
      ENCODING_DUMMY, UTF8, BINARY = SEAL.call(Encoding.instance_method(:dummy?), :bind_call), Encoding::UTF_8, Encoding::BINARY
      TYPES = [ Hash, Array, String, Integer, Float, TrueClass, FalseClass, NilClass ].freeze
      SCALAR_JSON = [ nil, nil, nil, nil, nil, "true".freeze, "false".freeze, "null".freeze ].freeze
      INDENTS = Array.new(MAX_DEPTH + 2) { |depth| ("  " * depth).freeze }.freeze
      ESCAPE_EXTRA = Array.new(256, 0)
      (0..31).each { |byte| ESCAPE_EXTRA[byte] = 5 }
      [ 8, 9, 10, 12, 13, 34, 92 ].each { |byte| ESCAPE_EXTRA[byte] = 1 }
      ESCAPE_EXTRA.freeze
      NODES, INPUT, ALLOCATION, ACTIVE = 0, 1, 2, 3
      COLLECTION_BYTES = lambda do |count, payload, depth|
        bytes = INTEGER_ADD.__invoke__(4, INTEGER_MULTIPLY.__invoke__(2, depth))
        entries = INTEGER_MULTIPLY.__invoke__(INTEGER_MULTIPLY.__invoke__(count, 2),
                                             INTEGER_ADD.__invoke__(depth, 1))
        commas = INTEGER_MULTIPLY.__invoke__(INTEGER_SUBTRACT.__invoke__(count, 1), 2)
        INTEGER_ADD.__invoke__(bytes, INTEGER_ADD.__invoke__(entries, INTEGER_ADD.__invoke__(commas, payload)))
      end.freeze
      class << self
        def capture(value)
          state = [ 0, 0, 0, {} ]
          owned, fragment = import(value, state, 0)
          canonical = STRING_INITIALIZE.__invoke__(CLASS_ALLOCATE.__invoke__(String), encoding: UTF8)
          reserve!(state, INTEGER_ADD.__invoke__(STRING_BYTESIZE.__invoke__(fragment), 1))
          STRING_APPEND.__invoke__(STRING_APPEND.__invoke__(canonical, fragment), "\n")
          OBJECT_FREEZE.__invoke__(canonical)
          snapshot = CLASS_ALLOCATE.__invoke__(Snapshot)
          DATA_INITIALIZE.__invoke__(snapshot, value: owned, canonical_bytes: canonical)
          snapshot
        rescue Error, EncodingError, JSON::GeneratorError, TypeError, ArgumentError
          raise Error, "workflow-creator value cannot be captured", cause: nil
        end
        private
        def import(value, state, depth)
          raise Error if INTEGER_GREATER.__invoke__(depth, MAX_DEPTH)
          nodes = INTEGER_ADD.__invoke__(ARRAY_GET.__invoke__(state, NODES), 1)
          raise Error if INTEGER_GREATER.__invoke__(nodes, MAX_NODES)
          ARRAY_SET.__invoke__(state, NODES, nodes)
          reserve!(state, 64)
          klass = OBJECT_CLASS.__invoke__(value)
          index = ARRAY_INDEX.__invoke__(TYPES) { |type| OBJECT_EQUAL.__invoke__(klass, type) }
          handler = ARRAY_GET.__invoke__(HANDLERS, index)
          raise Error unless handler
          PROC_CALL.__invoke__(handler, value, state, depth)
        end
        def import_hash(value, state, depth)
          active = ARRAY_GET.__invoke__(state, ACTIVE)
          identity = OBJECT_ID.__invoke__(value)
          raise Error if HASH_KEY.__invoke__(active, identity)
          HASH_SET.__invoke__(active, identity, true)
          minimum_nodes = INTEGER_ADD.__invoke__(ARRAY_GET.__invoke__(state, NODES), INTEGER_MULTIPLY.__invoke__(HASH_LENGTH.__invoke__(value), 2))
          raise Error if INTEGER_GREATER.__invoke__(minimum_nodes, MAX_NODES)
          entries = []
          seen, payload = {}, 0
          HASH_EACH_PAIR.__invoke__(value) do |raw_key, raw_value|
            raise Error unless OBJECT_EQUAL.__invoke__(OBJECT_CLASS.__invoke__(raw_key), String)
            key, key_json = import(raw_key, state, INTEGER_ADD.__invoke__(depth, 1))
            raise Error if HASH_KEY.__invoke__(seen, key)
            HASH_SET.__invoke__(seen, key, true)
            nested, nested_json = import(raw_value, state, INTEGER_ADD.__invoke__(depth, 1))
            entry_bytes = INTEGER_ADD.__invoke__(STRING_BYTESIZE.__invoke__(key_json),
                                                 INTEGER_ADD.__invoke__(STRING_BYTESIZE.__invoke__(nested_json), 2))
            payload = INTEGER_ADD.__invoke__(payload, entry_bytes)
            ARRAY_PUSH.__invoke__(entries, [ key, key_json, nested, nested_json ])
          end
          ARRAY_SORT.__invoke__(entries) do |left, right|
            STRING_COMPARE.__invoke__(ARRAY_GET.__invoke__(left, 0), ARRAY_GET.__invoke__(right, 0))
          end
          build_collection({}, entries, payload, state, depth, [ "{", "}", "{}" ], HASH_ENTRY_BUILDER)
        ensure
          HASH_DELETE.__invoke__(active, identity)
        end
        def import_array(value, state, depth)
          active = ARRAY_GET.__invoke__(state, ACTIVE)
          identity = OBJECT_ID.__invoke__(value)
          raise Error if HASH_KEY.__invoke__(active, identity)
          HASH_SET.__invoke__(active, identity, true)
          entries, payload = [], 0
          ARRAY_EACH.__invoke__(value) do |nested|
            owned, fragment = import(nested, state, INTEGER_ADD.__invoke__(depth, 1))
            payload = INTEGER_ADD.__invoke__(payload, STRING_BYTESIZE.__invoke__(fragment))
            ARRAY_PUSH.__invoke__(entries, [ nil, nil, owned, fragment ])
          end
          build_collection([], entries, payload, state, depth, [ "[", "]", "[]" ], ARRAY_ENTRY_BUILDER)
        ensure
          HASH_DELETE.__invoke__(active, identity)
        end
        def build_collection(result, entries, payload, state, depth, delimiters, entry_builder)
          count = ARRAY_LENGTH.__invoke__(entries)
          if INTEGER_ZERO.__invoke__(count)
            reserve!(state, 2)
            return [ OBJECT_FREEZE.__invoke__(result), ARRAY_GET.__invoke__(delimiters, 2) ]
          end
          reserve!(state, PROC_CALL.__invoke__(COLLECTION_BYTES, count, payload, depth))
          output = STRING_INITIALIZE.__invoke__(CLASS_ALLOCATE.__invoke__(String), encoding: UTF8)
          STRING_APPEND.__invoke__(output, ARRAY_GET.__invoke__(delimiters, 0))
          STRING_APPEND.__invoke__(output, "\n")
          separator = ""
          indent = ARRAY_GET.__invoke__(INDENTS, INTEGER_ADD.__invoke__(depth, 1))
          ARRAY_EACH.__invoke__(entries) do |entry|
            parts = PROC_CALL.__invoke__(entry_builder, result, entry, separator, indent)
            ARRAY_EACH.__invoke__(parts) { |part| STRING_APPEND.__invoke__(output, part) }
            separator = ",\n"
          end
          tail = [ "\n", ARRAY_GET.__invoke__(INDENTS, depth), ARRAY_GET.__invoke__(delimiters, 1) ]
          ARRAY_EACH.__invoke__(tail) { |part| STRING_APPEND.__invoke__(output, part) }
          [ OBJECT_FREEZE.__invoke__(result), output ]
        end
        def import_string(value, state, _depth)
          encoding = STRING_ENCODING.__invoke__(value)
          raise Error if ENCODING_DUMMY.__invoke__(encoding)
          raise Error if OBJECT_EQUAL.__invoke__(encoding, BINARY)
          raw_size = STRING_BYTESIZE.__invoke__(value)
          input = INTEGER_ADD.__invoke__(ARRAY_GET.__invoke__(state, INPUT), raw_size)
          raise Error if INTEGER_GREATER.__invoke__(input, MAX_INPUT_BYTES)
          ARRAY_SET.__invoke__(state, INPUT, input)
          reserve!(state, INTEGER_MULTIPLY.__invoke__(raw_size, 4))
          owned = STRING_ENCODE.__invoke__(value, UTF8)
          token_size = INTEGER_ADD.__invoke__(STRING_BYTESIZE.__invoke__(owned), 2)
          STRING_EACH_BYTE.__invoke__(owned) do |byte|
            token_size = INTEGER_ADD.__invoke__(token_size, ARRAY_GET.__invoke__(ESCAPE_EXTRA, byte))
          end
          reserve!(state, token_size)
          token = JSON_GENERATE.__invoke__(owned, nil, nil)
          [ OBJECT_FREEZE.__invoke__(owned), token ]
        end
        def reserve!(state, bytes)
          raise Error if INTEGER_GREATER.__invoke__(bytes, MAX_PROJECTED_BYTES)
          total = INTEGER_ADD.__invoke__(ARRAY_GET.__invoke__(state, ALLOCATION), bytes)
          raise Error if INTEGER_GREATER.__invoke__(total, MAX_ALLOCATION_BYTES)
          ARRAY_SET.__invoke__(state, ALLOCATION, total)
        end
      end
      HASH_ENTRY_BUILDER = lambda do |result, entry, separator, indent|
        HASH_SET.__invoke__(result, ARRAY_GET.__invoke__(entry, 0), ARRAY_GET.__invoke__(entry, 2))
        [ separator, indent, ARRAY_GET.__invoke__(entry, 1), ": ", ARRAY_GET.__invoke__(entry, 3) ]
      end.freeze
      ARRAY_ENTRY_BUILDER = lambda do |result, entry, separator, indent|
        ARRAY_PUSH.__invoke__(result, ARRAY_GET.__invoke__(entry, 2))
        [ separator, indent, ARRAY_GET.__invoke__(entry, 3) ]
      end.freeze
      HANDLERS = [
        method(:import_hash).to_proc, method(:import_array).to_proc, method(:import_string).to_proc, lambda do |value, state, _depth|
          raise Error if INTEGER_GREATER.__invoke__(INTEGER_BITS.__invoke__(value), MAX_INTEGER_BITS)
          token = INTEGER_TO_S.__invoke__(value)
          reserve!(state, STRING_BYTESIZE.__invoke__(token))
          [ value, token ]
        end,
        lambda do |value, state, _depth|
          token = JSON_GENERATE.__invoke__(value, nil, nil)
          reserve!(state, STRING_BYTESIZE.__invoke__(token))
          [ value, token ]
        end,
        ->(value, _state, _depth) { [ value, ARRAY_GET.__invoke__(SCALAR_JSON, 5) ] },
        ->(value, _state, _depth) { [ value, ARRAY_GET.__invoke__(SCALAR_JSON, 6) ] },
        ->(value, _state, _depth) { [ value, ARRAY_GET.__invoke__(SCALAR_JSON, 7) ] }
      ].each(&:freeze).freeze
      private_constant :SEAL, :CLASS_ALLOCATE, :DATA_INITIALIZE, :STRING_INITIALIZE, :JSON_GENERATE
      [ Error, Snapshot, self ].each { |object| OBJECT_FREEZE.__invoke__(object) }
    end
  end
end
require_relative "workflow_creator_text_safety"
