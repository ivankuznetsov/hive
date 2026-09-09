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
        invalid!(:json, error.message)
      end

      def load_json(value)
        source = String(value)
        parsed = JSON.parse(source)
        canonical = dump_json(parsed)
        invalid!(:json, "is not canonical", canonical: true) unless canonical == source
        parsed
      rescue JSON::ParserError, TypeError => error
        invalid!(:json, error.message)
      end

      def dump_time(value)
        unless value.respond_to?(:utc)
          invalid!(:timestamp, "must be time-like")
        end

        value.utc.iso8601(6)
      rescue ArgumentError => error
        invalid!(:timestamp, error.message)
      end

      def load_time(value)
        source = String(value)
        parsed = Time.iso8601(source)
        canonical = dump_time(parsed)
        invalid!(:timestamp, "must be canonical UTC with microseconds", canonical: true) unless
          source == canonical
        parsed.utc
      rescue ArgumentError, TypeError => error
        raise error if error.is_a?(CodecError)

        invalid!(:timestamp, error.message)
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
        string = if value.encoding == Encoding::BINARY
          value.dup.force_encoding(Encoding::UTF_8)
        else
          value.encode(Encoding::UTF_8)
        end
        raise ArgumentError, "canonical JSON requires valid UTF-8" unless string.valid_encoding?

        string.unicode_normalize(:nfc)
      rescue EncodingError
        raise ArgumentError, "canonical JSON requires valid UTF-8"
      end

      def invalid!(kind, detail, canonical: false)
        label = kind == :json ? "runtime control-plane JSON" : "runtime timestamp"
        message = canonical ? "#{label} #{detail}" : "#{label} is invalid: #{detail}"
        raise CodecError.new(message, code: :"#{canonical ? 'noncanonical' : 'invalid'}_#{kind}")
      end
    end
  end
end
