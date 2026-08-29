require "json"
require "time"
require "unicode_normalize/normalize"

module Hive
  module RuntimeControlPlane
    module Codec
      module_function

      def dump_json(value)
        JSON.generate(normalize(value))
      rescue JSON::GeneratorError, EncodingError, ArgumentError => error
        raise CodecError.new(
          "runtime control-plane JSON is invalid: #{error.message}",
          code: :invalid_json
        )
      end

      def load_json(value)
        source = String(value)
        parsed = JSON.parse(source)
        canonical = dump_json(parsed)
        unless canonical == source
          raise CodecError.new(
            "runtime control-plane JSON is not canonical",
            code: :noncanonical_json
          )
        end
        parsed
      rescue JSON::ParserError, TypeError => error
        raise CodecError.new(
          "runtime control-plane JSON is invalid: #{error.message}",
          code: :invalid_json
        )
      end

      def dump_time(value)
        unless value.respond_to?(:utc)
          raise CodecError.new("runtime timestamp must be time-like", code: :invalid_timestamp)
        end

        value.utc.iso8601(6)
      rescue ArgumentError => error
        raise CodecError.new(
          "runtime timestamp is invalid: #{error.message}", code: :invalid_timestamp
        )
      end

      def load_time(value)
        source = String(value)
        parsed = Time.iso8601(source)
        canonical = dump_time(parsed)
        unless source == canonical
          raise CodecError.new(
            "runtime timestamp must be canonical UTC with microseconds",
            code: :noncanonical_timestamp
          )
        end
        parsed.utc
      rescue ArgumentError, TypeError => error
        raise error if error.is_a?(CodecError)

        raise CodecError.new(
          "runtime timestamp is invalid: #{error.message}", code: :invalid_timestamp
        )
      end

      def normalize(value)
        case value
        when Hash
          value.each_with_object({}) do |(key, child), result|
            normalized_key = normalize_string(key.to_s)
            if result.key?(normalized_key)
              raise ArgumentError, "canonical JSON contains duplicate normalized key #{normalized_key.inspect}"
            end
            result[normalized_key] = normalize(child)
          end.sort.to_h
        when Array
          value.map { |child| normalize(child) }
        when String
          normalize_string(value)
        when Symbol
          value.to_s
        when Integer, TrueClass, FalseClass, NilClass
          value
        when Float
          raise ArgumentError, "canonical JSON does not permit non-finite numbers" unless value.finite?

          value
        else
          raise ArgumentError, "canonical JSON cannot encode #{value.class}"
        end
      end

      def normalize_string(value)
        string = value.encode(Encoding::UTF_8)
        raise ArgumentError, "canonical JSON requires valid UTF-8" unless string.valid_encoding?

        string.unicode_normalize(:nfc)
      rescue EncodingError
        raise ArgumentError, "canonical JSON requires valid UTF-8"
      end
    end
  end
end
