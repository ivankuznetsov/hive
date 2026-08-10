require "json"
require "json_schemer"
require "pathname"
require "hive"
require "hive/attempts/record"

module Hive
  module Attempts
    # The only supported forward conversion into the runtime attempt schema.
    # Runtime readers remain v4-only: migration owns every interpretation of a
    # historical v3 document and never synthesizes an explicit routing policy.
    module RecordMigration
      LEGACY_VERSION = 3

      module_function

      def convert_v3(data)
        source = deep_copy(data)
        validate_v3!(source)

        source["schema_version"] = Record::SCHEMA_VERSION
        source["routing"] = { "mode" => "legacy" }
        if source["receipt"]
          source["receipt"]["receipt_version"] = 1
          source["receipt"]["terminal_lease_version"] = source.fetch("lease_version")
          source["receipt"]["provider_evidence"] = nil
        end

        Record.new(source).to_h
      end

      def current_or_convert(data)
        return Record.new(data).to_h if data.is_a?(Hash) && data["schema_version"] == Record::SCHEMA_VERSION

        convert_v3(data)
      end

      def v3?(data)
        data.is_a?(Hash) && data["schema"] == Record::SCHEMA &&
          data["schema_version"] == LEGACY_VERSION
      end

      def validate_v3!(data)
        unless v3?(data) && v3_schemer.valid?(data)
          raise InvalidRecord, "attempt record is not a valid schema-v3 document"
        end

        true
      end

      def v3_schemer
        @v3_schemer ||= JSONSchemer.schema(
          Pathname.new(Hive::Schemas.schema_path("hive-attempt", version: LEGACY_VERSION))
        )
      end
      private_class_method :v3_schemer

      def deep_copy(value)
        JSON.parse(JSON.generate(value))
      rescue JSON::GeneratorError, TypeError => error
        raise InvalidRecord, "attempt record is not JSON-safe: #{error.message}"
      end
      private_class_method :deep_copy
    end
  end
end
