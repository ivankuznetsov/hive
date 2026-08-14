require "json"
require "json_schemer"
require "pathname"
require "hive"

module Hive
  module Artifacts
    module OutcomeEvidence
      class Error < Hive::Error; end
      class ResolutionError < Error; end
      class StoreError < Error; end

      module Document
        class DuplicateKeyError < JSON::ParserError; end

        class StrictHash < Hash
          def []=(key, value)
            raise DuplicateKeyError, "duplicate JSON key: #{key}" if key?(key)

            super
          end
        end

        module_function

        def parse(source, schema:, label:, version: nil)
          value = JSON.parse(
            source, object_class: StrictHash, allow_duplicate_key: false
          )
          unless value.is_a?(Hash)
            raise StoreError, "#{label} must contain a JSON object"
          end

          schemer = JSONSchemer.schema(
            Pathname.new(Hive::Schemas.schema_path(schema, version: version))
          )
          errors = schemer.validate(value).take(3).map do |error|
            pointer = error.fetch("data_pointer", "")
            type = error.fetch("type", "invalid")
            "#{pointer.empty? ? '/' : pointer}: #{type}"
          end
          unless errors.empty?
            raise StoreError, "#{label} violates #{schema}: #{errors.join(', ')}"
          end

          value
        rescue JSON::ParserError => e
          raise StoreError, "#{label} is invalid JSON: #{e.message}"
        end

        def generate(value, schema:, label:, version: nil)
          source = "#{JSON.generate(value)}\n"
          parse(source, schema: schema, label: label, version: version)
          source
        end
      end
    end
  end
end
