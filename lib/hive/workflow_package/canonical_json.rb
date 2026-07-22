require "json"

module Hive
  module WorkflowPackage
    module CanonicalJSON
      module_function

      def generate(value)
        "#{JSON.generate(normalize(value))}\n"
      end
      alias dump generate

      def parse(bytes)
        JSON.parse(bytes)
      end

      def normalize(value)
        case value
        when Hash
          value.each_with_object({}) do |(key, child), out|
            normalized_key = normalize_string(key.to_s)
            out[normalized_key] = normalize(child)
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
