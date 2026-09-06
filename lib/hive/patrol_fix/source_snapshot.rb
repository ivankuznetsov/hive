require "digest"
require "json"
require "time"
require "hive/patrol_fix"
require "hive/secret_patterns"
require "hive/secret_scanner"
require "hive/patrol_fix/publication_receipt"

module Hive
  module PatrolFix
    # Immutable, source-neutral admission input. Source stores remain evidence
    # authorities; this value is only the bounded byte snapshot handed across
    # the source/admission lock boundary.
    class SourceSnapshot
      SCHEMA = "hive-patrol-fix-source-snapshot".freeze
      SCHEMA_VERSION = 1
      ENGINES = %w[ordinary_patrol architecture_patrol].freeze
      MAX_BYTES = 256 * 1024
      MAX_TEXT_BYTES = 16 * 1024
      MAX_SHORT_TEXT_BYTES = 512
      MAX_EVIDENCE = 64
      MAX_PATHS = 256
      MAX_LINEAGE = 64
      MAX_ALIASES = 128
      MAX_ISSUES = 64
      MAX_PULL_REQUESTS = 64
      REVISION = /\A[0-9a-f]{40}\z/
      ALIAS_KINDS = %w[
        ordinary_finding architecture_thesis canonical_task legacy_issue external_issue
      ].freeze

      class InvalidSnapshot < Hive::Error; end

      attr_reader :canonical_bytes, :digest, :evidence_digest

      class << self
        def build(engine:, identity:, title:, summary:, target_revision:, evidence:,
                  affected_code:, reproduction_guidance:, discovery_run:,
                  semantic_lineage:, aliases:, external_issues:,
                  existing_pull_requests:, accepted_at:)
          new(
            "schema" => SCHEMA,
            "schema_version" => SCHEMA_VERSION,
            "engine" => engine,
            "identity" => identity,
            "title" => title,
            "summary" => summary,
            "target_revision" => target_revision,
            "evidence" => evidence,
            "affected_code" => affected_code,
            "reproduction_guidance" => reproduction_guidance,
            "discovery_run" => discovery_run,
            "semantic_lineage" => semantic_lineage,
            "aliases" => aliases,
            "external_issues" => external_issues,
            "existing_pull_requests" => existing_pull_requests,
            "accepted_at" => accepted_at
          )
        end

        def parse(bytes)
          invalid!("snapshot exceeds the size limit") if bytes.to_s.bytesize > MAX_BYTES
          new(JSON.parse(bytes.to_s))
        rescue JSON::ParserError, EncodingError
          invalid!("snapshot is malformed JSON")
        end

        def invalid!(message)
          raise InvalidSnapshot, Hive::SecretPatterns.redact(message.to_s)[0, 512]
        end
      end

      def initialize(document)
        @document = validate!(PatrolFix.deep_copy(document))
        @canonical_bytes = PatrolFix.canonical_json(@document).freeze
        invalid!("snapshot exceeds the size limit") if @canonical_bytes.bytesize > MAX_BYTES
        @digest = Digest::SHA256.hexdigest(@canonical_bytes).freeze
        @evidence_digest = Digest::SHA256.hexdigest(
          PatrolFix.canonical_json(material_evidence)
        ).freeze
      rescue JSON::GeneratorError, ArgumentError, TypeError
        invalid!("snapshot is not JSON serializable")
      end

      def to_h = @document

      def source_manifest_entry
        {
          "engine" => @document.fetch("engine"),
          "identity" => @document.fetch("identity"),
          "target_revision" => @document.fetch("target_revision"),
          "evidence" => @document.fetch("evidence"),
          "affected_code" => @document.fetch("affected_code"),
          "reproduction_guidance" => @document.fetch("reproduction_guidance"),
          "discovery_run" => @document.fetch("discovery_run"),
          "semantic_lineage" => @document.fetch("semantic_lineage")
        }
      end

      private

      def validate!(document)
        hash!(document, "snapshot")
        exact_keys!(document, %w[
          schema schema_version engine identity title summary target_revision
          evidence affected_code reproduction_guidance discovery_run
          semantic_lineage aliases external_issues existing_pull_requests accepted_at
        ], "snapshot")
        invalid!("unknown snapshot schema") unless document["schema"] == SCHEMA
        invalid!("unknown snapshot schema version") unless document["schema_version"] == SCHEMA_VERSION
        invalid!("unknown source engine") unless ENGINES.include?(document["engine"])
        string!(document.fetch("identity"), "identity", max: MAX_SHORT_TEXT_BYTES)
        string!(document.fetch("title"), "title", max: 2_048)
        string!(document.fetch("summary"), "summary", max: MAX_TEXT_BYTES)
        string!(document.fetch("target_revision"), "target_revision", max: 40, pattern: REVISION)
        string_array!(document.fetch("evidence"), "evidence", min: 1,
                      max: MAX_EVIDENCE, item_max: MAX_TEXT_BYTES)
        paths = string_array!(document.fetch("affected_code"), "affected_code", min: 1,
                              max: MAX_PATHS, item_max: 1_024)
        paths.each { |path| safe_relative_path!(path) }
        string!(document.fetch("reproduction_guidance"), "reproduction_guidance", max: MAX_TEXT_BYTES)
        string!(document.fetch("discovery_run"), "discovery_run", max: MAX_SHORT_TEXT_BYTES)
        string_array!(document.fetch("semantic_lineage"), "semantic_lineage", min: 1,
                      max: MAX_LINEAGE, item_max: MAX_SHORT_TEXT_BYTES)
        array!(document.fetch("aliases"), "aliases", max: MAX_ALIASES).each_with_index do |entry, index|
          validate_alias!(entry, index)
        end
        array!(document.fetch("external_issues"), "external_issues", max: MAX_ISSUES).each_with_index do |entry, index|
          validate_issue!(entry, index)
        end
        array!(document.fetch("existing_pull_requests"), "existing_pull_requests",
               max: MAX_PULL_REQUESTS).each_with_index do |entry, index|
          validate_pull_request!(entry, index)
        end
        timestamp!(document.fetch("accepted_at"), "accepted_at")
        if Hive::SecretScanner.match?(PatrolFix.canonical_json(document))
          invalid!("snapshot contains secret-like material")
        end
        PatrolFix.deep_freeze(document)
      end

      def validate_alias!(entry, index)
        hash!(entry, "aliases[#{index}]")
        exact_keys!(entry, %w[kind value], "aliases[#{index}]")
        invalid!("aliases[#{index}].kind is unknown") unless ALIAS_KINDS.include?(entry["kind"])
        string!(entry.fetch("value"), "aliases[#{index}].value", max: 2_048)
      end

      def validate_issue!(entry, index)
        label = "external_issues[#{index}]"
        hash!(entry, label)
        exact_keys!(entry, %w[url number], label)
        string!(entry.fetch("url"), "#{label}.url", max: 2_048)
        positive_integer!(entry.fetch("number"), "#{label}.number")
      end

      def validate_pull_request!(entry, index)
        label = "existing_pull_requests[#{index}]"
        PublicationReceipt.validate_payload!(entry)
      rescue PublicationReceipt::InvalidPublication
        invalid!("#{label} is not an exact canonical publication")
      end

      def material_evidence
        @document.slice(
          "title", "summary", "target_revision", "evidence", "affected_code",
          "reproduction_guidance", "semantic_lineage"
        )
      end

      def exact_keys!(value, keys, label)
        invalid!("#{label} fields are invalid") unless value.keys.sort == keys.sort
      end

      def hash!(value, label)
        invalid!("#{label} must be an object") unless value.is_a?(Hash)
      end

      def array!(value, label, min: 0, max:)
        invalid!("#{label} must be an array") unless value.is_a?(Array)
        invalid!("#{label} must contain at least #{min} entries") if value.length < min
        invalid!("#{label} exceeds #{max} entries") if value.length > max
        value
      end

      def string_array!(value, label, min:, max:, item_max:)
        array!(value, label, min: min, max: max).each_with_index do |entry, index|
          string!(entry, "#{label}[#{index}]", max: item_max)
        end
      end

      def string!(value, label, max:, pattern: nil)
        invalid!("#{label} must be non-empty text") unless value.is_a?(String) && !value.empty?
        invalid!("#{label} exceeds #{max} bytes") if value.bytesize > max
        invalid!("#{label} contains control characters") if value.match?(/[\u0000-\u001f\u007f]/)
        invalid!("#{label} has an invalid format") if pattern && !value.match?(pattern)
      end

      def positive_integer!(value, label)
        invalid!("#{label} must be a positive integer") unless value.is_a?(Integer) && value.positive?
      end

      def safe_relative_path!(path)
        invalid!("affected_code must contain relative repository paths") if
          path.start_with?("/") || path.include?("\\") || path.split("/").include?("..")
      end

      def timestamp!(value, label)
        string!(value, label, max: 64)
        parsed = Time.iso8601(value)
        invalid!("#{label} must be UTC") unless parsed.utc? && value.end_with?("Z")
      rescue ArgumentError
        invalid!("#{label} must be an ISO 8601 UTC timestamp")
      end

      def invalid!(message) = self.class.invalid!(message)
    end
  end
end
