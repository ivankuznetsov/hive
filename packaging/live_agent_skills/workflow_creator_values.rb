require "json"
module HiveLiveAgentProof
  module WorkflowCreator
    module Values
      class Error < StandardError; end
      Snapshot = Data.define(:value, :canonical_bytes).tap do |type|
        type.singleton_class.send(:private, :new, :[], :allocate)
        type.send(:private, :with)
      end
      MAX_DEPTH, MAX_NODES, MAX_INTEGER_BITS = 64, 8_192, 4_096
      MAX_INPUT_BYTES, MAX_PROJECTED_BYTES, MAX_ALLOCATION_BYTES = 262_144, 1_048_576, 4_194_304
      OBJECT_CLASS, OBJECT_FREEZE = %i[class freeze].map { Object.instance_method(_1).freeze }
      OBJECT_EQUAL, OBJECT_ID = %i[equal? __id__].map { BasicObject.instance_method(_1).freeze }
      CLASS_NEW, CLASS_ALLOCATE, PROC_CALL =
        [ [ Class, :new ], [ Class, :allocate ], [ Proc, :call ] ].map { |owner, name| owner.instance_method(name).freeze }
      HASH_EACH_PAIR, HASH_KEY, HASH_SET, HASH_DELETE, HASH_LENGTH =
        %i[each_pair key? []= delete length].map { Hash.instance_method(_1).freeze }
      ARRAY_EACH, ARRAY_GET, ARRAY_SET, ARRAY_PUSH, ARRAY_INDEX, ARRAY_LENGTH, ARRAY_SORT, ARRAY_SUM =
        %i[each [] []= << index length sort! sum].map { Array.instance_method(_1).freeze }
      STRING_INITIALIZE, STRING_ENCODING, STRING_BYTESIZE, STRING_ENCODE, STRING_EACH_BYTE, STRING_TO_JSON, STRING_APPEND, STRING_COMPARE =
          %i[initialize encoding bytesize encode each_byte to_json << <=>].map { String.instance_method(_1).freeze }
      INTEGER_ADD, INTEGER_SUBTRACT, INTEGER_MULTIPLY, INTEGER_GREATER, INTEGER_ZERO, INTEGER_BITS, INTEGER_TO_S =
          %i[+ - * > zero? bit_length to_s].map { Integer.instance_method(_1).freeze }
      FLOAT_FINITE, FLOAT_TO_JSON = %i[finite? to_json].map { Float.instance_method(_1).freeze }
      ENCODING_DUMMY, UTF8, BINARY = Encoding.instance_method(:dummy?).freeze, Encoding::UTF_8, Encoding::BINARY
      TYPES = [ Hash, Array, String, Integer, Float, TrueClass, FalseClass, NilClass ].freeze
      SCALAR_JSON = [ nil, nil, nil, nil, nil, "true".freeze, "false".freeze, "null".freeze ].freeze
      INDENTS = Array.new(MAX_DEPTH + 2) { |depth| ("  " * depth).freeze }.freeze
      ESCAPE_EXTRA = Array.new(256, 0)
      (0..31).each { |byte| ESCAPE_EXTRA[byte] = 5 }
      [ 8, 9, 10, 12, 13, 34, 92 ].each { |byte| ESCAPE_EXTRA[byte] = 1 }
      ESCAPE_EXTRA.freeze
      NODES, INPUT, ALLOCATION, ACTIVE = 0, 1, 2, 3
      COLLECTION_BYTES = lambda do |count, payload, depth|
        bytes = INTEGER_ADD.bind_call(4, INTEGER_MULTIPLY.bind_call(2, depth))
        entries = INTEGER_MULTIPLY.bind_call(INTEGER_MULTIPLY.bind_call(count, 2),
                                             INTEGER_ADD.bind_call(depth, 1))
        commas = INTEGER_MULTIPLY.bind_call(INTEGER_SUBTRACT.bind_call(count, 1), 2)
        INTEGER_ADD.bind_call(bytes, INTEGER_ADD.bind_call(entries, INTEGER_ADD.bind_call(commas, payload)))
      end.freeze
      class << self
        def capture(value)
          state = [ 0, 0, 0, {} ]
          owned, fragment = import(value, state, 0)
          canonical = STRING_INITIALIZE.bind_call(CLASS_ALLOCATE.bind_call(String), encoding: UTF8)
          reserve!(state, INTEGER_ADD.bind_call(STRING_BYTESIZE.bind_call(fragment), 1))
          STRING_APPEND.bind_call(canonical, fragment)
          STRING_APPEND.bind_call(canonical, "\n")
          OBJECT_FREEZE.bind_call(canonical)
          CLASS_NEW.bind_call(Snapshot, value: owned, canonical_bytes: canonical)
        rescue Error, EncodingError, JSON::GeneratorError, TypeError, ArgumentError
          raise Error, "workflow-creator value cannot be captured"
        end
        private
        def import(value, state, depth)
          raise Error if INTEGER_GREATER.bind_call(depth, MAX_DEPTH)
          nodes = INTEGER_ADD.bind_call(ARRAY_GET.bind_call(state, NODES), 1)
          raise Error if INTEGER_GREATER.bind_call(nodes, MAX_NODES)
          ARRAY_SET.bind_call(state, NODES, nodes)
          reserve!(state, 64)
          klass = OBJECT_CLASS.bind_call(value)
          index = ARRAY_INDEX.bind_call(TYPES) { |type| OBJECT_EQUAL.bind_call(klass, type) }
          handler = ARRAY_GET.bind_call(HANDLERS, index)
          raise Error unless handler
          PROC_CALL.bind_call(handler, value, state, depth)
        end
        def import_hash(value, state, depth)
          active = ARRAY_GET.bind_call(state, ACTIVE)
          identity = OBJECT_ID.bind_call(value)
          raise Error if HASH_KEY.bind_call(active, identity)
          HASH_SET.bind_call(active, identity, true)
          minimum_nodes = INTEGER_ADD.bind_call(ARRAY_GET.bind_call(state, NODES), INTEGER_MULTIPLY.bind_call(HASH_LENGTH.bind_call(value), 2))
          raise Error if INTEGER_GREATER.bind_call(minimum_nodes, MAX_NODES)
          entries = []
          seen = {}
          payload = 0
          HASH_EACH_PAIR.bind_call(value) do |raw_key, raw_value|
            entry, entry_bytes = import_hash_entry(raw_key, raw_value, state, depth, seen)
            payload = INTEGER_ADD.bind_call(payload, entry_bytes)
            ARRAY_PUSH.bind_call(entries, entry)
          end
          ARRAY_SORT.bind_call(entries) do |left, right|
            STRING_COMPARE.bind_call(ARRAY_GET.bind_call(left, 0), ARRAY_GET.bind_call(right, 0))
          end
          build_collection({}, entries, payload, state, depth, [ "{", "}", "{}" ], HASH_ENTRY_BUILDER)
        ensure
          HASH_DELETE.bind_call(active, identity)
        end
        def import_hash_entry(raw_key, raw_value, state, depth, seen)
          raise Error unless OBJECT_EQUAL.bind_call(OBJECT_CLASS.bind_call(raw_key), String)
          nested_depth = INTEGER_ADD.bind_call(depth, 1)
          key, key_json = import(raw_key, state, nested_depth)
          raise Error if HASH_KEY.bind_call(seen, key)
          HASH_SET.bind_call(seen, key, true)
          nested, nested_json = import(raw_value, state, nested_depth)
          bytes = ARRAY_SUM.bind_call([ STRING_BYTESIZE.bind_call(key_json), STRING_BYTESIZE.bind_call(nested_json), 2 ])
          [ [ key, key_json, nested, nested_json ], bytes ]
        end
        def import_array(value, state, depth)
          active = ARRAY_GET.bind_call(state, ACTIVE)
          identity = OBJECT_ID.bind_call(value)
          raise Error if HASH_KEY.bind_call(active, identity)
          HASH_SET.bind_call(active, identity, true)
          entries = []
          payload = 0
          ARRAY_EACH.bind_call(value) do |nested|
            owned, fragment = import(nested, state, INTEGER_ADD.bind_call(depth, 1))
            payload = INTEGER_ADD.bind_call(payload, STRING_BYTESIZE.bind_call(fragment))
            ARRAY_PUSH.bind_call(entries, [ nil, nil, owned, fragment ])
          end
          build_collection([], entries, payload, state, depth, [ "[", "]", "[]" ], ARRAY_ENTRY_BUILDER)
        ensure
          HASH_DELETE.bind_call(active, identity)
        end
        def build_collection(result, entries, payload, state, depth, delimiters, entry_builder)
          count = ARRAY_LENGTH.bind_call(entries)
          if INTEGER_ZERO.bind_call(count)
            reserve!(state, 2)
            return [ OBJECT_FREEZE.bind_call(result), ARRAY_GET.bind_call(delimiters, 2) ]
          end
          reserve!(state, PROC_CALL.bind_call(COLLECTION_BYTES, count, payload, depth))
          output = STRING_INITIALIZE.bind_call(CLASS_ALLOCATE.bind_call(String), encoding: UTF8)
          STRING_APPEND.bind_call(output, ARRAY_GET.bind_call(delimiters, 0))
          STRING_APPEND.bind_call(output, "\n")
          separator = ""
          indent = ARRAY_GET.bind_call(INDENTS, INTEGER_ADD.bind_call(depth, 1))
          ARRAY_EACH.bind_call(entries) do |entry|
            parts = PROC_CALL.bind_call(entry_builder, result, entry, separator, indent)
            ARRAY_EACH.bind_call(parts) { |part| STRING_APPEND.bind_call(output, part) }
            separator = ",\n"
          end
          tail = [ "\n", ARRAY_GET.bind_call(INDENTS, depth), ARRAY_GET.bind_call(delimiters, 1) ]
          ARRAY_EACH.bind_call(tail) { |part| STRING_APPEND.bind_call(output, part) }
          [ OBJECT_FREEZE.bind_call(result), output ]
        end
        def import_string(value, state, _depth)
          encoding = STRING_ENCODING.bind_call(value)
          raise Error if ENCODING_DUMMY.bind_call(encoding)
          raise Error if OBJECT_EQUAL.bind_call(encoding, BINARY)
          raw_size = STRING_BYTESIZE.bind_call(value)
          input = INTEGER_ADD.bind_call(ARRAY_GET.bind_call(state, INPUT), raw_size)
          raise Error if INTEGER_GREATER.bind_call(input, MAX_INPUT_BYTES)
          ARRAY_SET.bind_call(state, INPUT, input)
          reserve!(state, INTEGER_MULTIPLY.bind_call(raw_size, 4))
          owned = STRING_ENCODE.bind_call(value, UTF8)
          token_size = INTEGER_ADD.bind_call(STRING_BYTESIZE.bind_call(owned), 2)
          STRING_EACH_BYTE.bind_call(owned) do |byte|
            token_size = INTEGER_ADD.bind_call(token_size, ARRAY_GET.bind_call(ESCAPE_EXTRA, byte))
          end
          reserve!(state, token_size)
          token = STRING_TO_JSON.bind_call(owned)
          [ OBJECT_FREEZE.bind_call(owned), token ]
        end
        def reserve!(state, bytes)
          raise Error if INTEGER_GREATER.bind_call(bytes, MAX_PROJECTED_BYTES)
          total = INTEGER_ADD.bind_call(ARRAY_GET.bind_call(state, ALLOCATION), bytes)
          raise Error if INTEGER_GREATER.bind_call(total, MAX_ALLOCATION_BYTES)
          ARRAY_SET.bind_call(state, ALLOCATION, total)
        end
      end
      HASH_ENTRY_BUILDER = lambda do |result, entry, separator, indent|
        HASH_SET.bind_call(result, ARRAY_GET.bind_call(entry, 0), ARRAY_GET.bind_call(entry, 2))
        [ separator, indent, ARRAY_GET.bind_call(entry, 1), ": ", ARRAY_GET.bind_call(entry, 3) ]
      end.freeze
      ARRAY_ENTRY_BUILDER = lambda do |result, entry, separator, indent|
        ARRAY_PUSH.bind_call(result, ARRAY_GET.bind_call(entry, 2))
        [ separator, indent, ARRAY_GET.bind_call(entry, 3) ]
      end.freeze
      HANDLERS = [
        method(:import_hash).to_proc, method(:import_array).to_proc, method(:import_string).to_proc, lambda do |value, state, _depth|
          raise Error if INTEGER_GREATER.bind_call(INTEGER_BITS.bind_call(value), MAX_INTEGER_BITS)
          token = INTEGER_TO_S.bind_call(value)
          reserve!(state, STRING_BYTESIZE.bind_call(token))
          [ value, token ]
        end,
        lambda do |value, state, _depth|
          raise Error unless FLOAT_FINITE.bind_call(value)
          token = FLOAT_TO_JSON.bind_call(value)
          reserve!(state, STRING_BYTESIZE.bind_call(token))
          [ value, token ]
        end,
        ->(value, _state, _depth) { [ value, ARRAY_GET.bind_call(SCALAR_JSON, 5) ] },
        ->(value, _state, _depth) { [ value, ARRAY_GET.bind_call(SCALAR_JSON, 6) ] },
        ->(value, _state, _depth) { [ value, ARRAY_GET.bind_call(SCALAR_JSON, 7) ] }
      ].each(&:freeze).freeze
      [ Error, Snapshot ].each(&:freeze)
    end
  end
end
require_relative "workflow_creator_text_safety"
