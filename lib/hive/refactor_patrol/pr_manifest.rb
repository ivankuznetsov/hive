require "digest"
require "json"
require "time"
require "hive"

module Hive
  module RefactorPatrol
    # Shared immutable PR-manifest contract used by intake, scheduling, and
    # daemon execution. Keeping validation and checksumming here prevents a
    # producer and consumer from accepting subtly different artifacts.
    module PrManifest
      SCHEMA = "hive-refactor-patrol-pr-manifest".freeze
      SCHEMA_VERSION = 2
      TOP_LEVEL_KEYS = %w[
        schema schema_version job_id source files changed_paths manifest_checksum
      ].freeze
      SOURCE_KEYS = %w[
        url number repository registration base_branch base_sha merge_sha merged_at
      ].freeze
      FILE_STATUSES = %w[added removed modified renamed copied changed unchanged].freeze

      class Invalid < Hive::ConfigError; end

      module_function

      def build(source:, files:)
        occurrence = [
          source.fetch("registration"), source.fetch("repository"),
          source.fetch("number"), source.fetch("merge_sha")
        ].join("\0")
        payload = {
          "schema" => SCHEMA,
          "schema_version" => SCHEMA_VERSION,
          "job_id" => "pr-#{source.fetch('number')}-#{::Digest::SHA256.hexdigest(occurrence)[0, 16]}",
          "source" => source,
          "files" => files,
          "changed_paths" => files.map { |file| file.fetch("path") }
        }
        payload.merge("manifest_checksum" => checksum(payload))
      end

      def load!(path, expected_job_id: nil, registration: nil, default_branch: nil)
        validate!(
          JSON.parse(File.binread(path)),
          expected_job_id: expected_job_id,
          registration: registration,
          default_branch: default_branch
        )
      rescue JSON::ParserError, SystemCallError, IOError, KeyError, ArgumentError => e
        raise Invalid, "cannot read refactor patrol job manifest (#{e.class}: #{e.message})"
      end

      def validate!(manifest, expected_job_id: nil, registration: nil, default_branch: nil)
        unless manifest.is_a?(Hash) && manifest.keys.sort == TOP_LEVEL_KEYS.sort &&
               manifest["schema"] == SCHEMA && manifest["schema_version"] == SCHEMA_VERSION
          raise Invalid, "refactor patrol job manifest schema is invalid"
        end
        if expected_job_id && manifest.fetch("job_id").to_s != expected_job_id.to_s
          raise Invalid, "refactor patrol job manifest id does not match its filename"
        end

        validate_source!(manifest.fetch("source"), registration: registration, default_branch: default_branch)
        files = manifest.fetch("files")
        changed_paths = manifest.fetch("changed_paths")
        unless files.is_a?(Array) && files.all? { |file| valid_file?(file) } &&
               changed_paths == files.map { |file| file.fetch("path") } && changed_paths.uniq == changed_paths
          raise Invalid, "refactor patrol job manifest file scope is invalid"
        end

        expected = checksum(manifest.reject { |key, _value| key == "manifest_checksum" })
        unless manifest.fetch("manifest_checksum").to_s == expected
          raise Invalid, "refactor patrol job manifest checksum is invalid"
        end
        manifest
      rescue KeyError, ArgumentError => e
        raise Invalid, "refactor patrol job manifest is incomplete (#{e.class}: #{e.message})"
      end

      def checksum(payload)
        ::Digest::SHA256.hexdigest(canonical_json(payload))
      end

      def valid_file?(file)
        return false unless file.is_a?(Hash)
        return false unless (file.keys - %w[path status previous_path]).empty?
        return false unless %w[path status].all? { |key| file.key?(key) }
        return false unless FILE_STATUSES.include?(file["status"])

        [ file["path"], file["previous_path"] ].compact.all? { |path| valid_relative_path?(path) }
      end

      def valid_relative_path?(path)
        value = path.to_s
        parts = value.split("/", -1)
        !value.empty? && !value.start_with?("/") && !value.include?("\\") &&
          !value.include?("\0") && parts.none? { |part| part.empty? || %w[. ..].include?(part) }
      end

      def canonical_json(value)
        JSON.generate(canonical_json_value(value))
      end

      def canonical_json_value(value)
        case value
        when Hash
          value.keys.sort.to_h { |key| [ key, canonical_json_value(value.fetch(key)) ] }
        when Array
          value.map { |item| canonical_json_value(item) }
        else
          value
        end
      end

      def validate_source!(source, registration:, default_branch:)
        unless source.is_a?(Hash) && source.keys.sort == SOURCE_KEYS.sort
          raise Invalid, "refactor patrol job manifest source is invalid"
        end
        if registration && source["registration"] != registration.to_s
          raise Invalid, "refactor patrol job manifest source does not match this registration"
        end
        if default_branch && source["base_branch"] != default_branch.to_s
          raise Invalid, "refactor patrol job manifest source does not match this registration"
        end
        unless source["number"].is_a?(Integer) && source["number"].positive? &&
               (SOURCE_KEYS - [ "number" ]).all? { |key| source[key].is_a?(String) && !source[key].empty? }
          raise Invalid, "refactor patrol job manifest source fields are invalid"
        end
        Time.iso8601(source.fetch("merged_at"))
      end
      private_class_method :canonical_json_value, :validate_source!
    end
  end
end
