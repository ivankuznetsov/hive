require "json"
require "hive"
require_relative "diff_walker"
require_relative "schemas"

module Hive
  module E2E
    class JsonValidator
      ValidationResult = Data.define(:status, :errors, :parse_error, :schema_path) do
        def ok?
          status == :ok
        end
      end

      def initialize
        @schemers = {}
      end

      def validate(command_name, document)
        schema_name = normalize_schema_name(command_name)
        path = schema_path(schema_name)
        return ValidationResult.new(status: :no_schema, errors: [], parse_error: nil, schema_path: nil) unless path && File.exist?(path)

        doc = parse_document(document)
        errors = validation_errors(schemer(schema_name, path).validate(doc))
        status = errors.empty? ? :ok : :invalid
        ValidationResult.new(status: status, errors: errors, parse_error: nil, schema_path: path)
      rescue JSON::ParserError => e
        ValidationResult.new(status: :invalid, errors: [], parse_error: e.message, schema_path: path)
      end

      private

      def parse_document(document)
        return document if document.is_a?(Hash) || document.is_a?(Array)

        JSON.parse(document.to_s)
      end

      def normalize_schema_name(command_name)
        name = command_name.to_s
        name.start_with?("hive-") ? name : "hive-#{name}"
      end

      def schema_path(schema_name)
        return Hive::Schemas.schema_path(schema_name) if Hive::Schemas::SCHEMA_VERSIONS.key?(schema_name)
        return Hive::E2E::Schemas.schema_path(schema_name) if Hive::E2E::Schemas::VERSIONS.key?(schema_name)

        nil
      end

      def schemer(schema_name, path)
        @schemers[schema_name] ||= begin
          require "json_schemer"
          JSONSchemer.schema(JSON.parse(File.read(path)), output_format: "basic")
        end
      end

      def validation_errors(raw)
        if raw.is_a?(Hash)
          return [] if raw["valid"] == true || raw[:valid] == true

          return Array(raw["errors"] || raw[:errors] || raw)
        end

        raw.to_a.reject { |error| error.respond_to?(:[]) && (error["valid"] == true || error[:valid] == true) }
      end
    end
  end
end
