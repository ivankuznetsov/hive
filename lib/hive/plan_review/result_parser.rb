require "digest"
require "json"
require "set"
require "time"
require "hive/plan_review/adapters/base"
require "hive/plan_review/finding"
require "hive/plan_review/record"

module Hive
  module PlanReview
    module ResultParser
      SCHEMA = "hive-plan-review-adapter-result".freeze
      SCHEMA_VERSION = 1
      MAX_BYTES = 1024 * 1024
      OUTCOMES = Adapters::Base::OUTCOMES
      LENS_NAME = /\A[a-z][a-z0-9_-]{0,63}\z/.freeze
      SELECTED_LENSES_CONTRACT_VERSION = 2
      LEGACY_SELECTED_LENSES_DIAGNOSTIC =
        "plan review selected_lenses must contain lowercase names".freeze
      RESIDUAL_EVIDENCE_CONTRACT_VERSION = 1
      LEGACY_RESIDUAL_EVIDENCE_DIAGNOSTIC =
        "invalid plan review residual evidence entry".freeze
      INITIAL_REVIEW_RECOVERY_ROLES = %w[primary adversarial].freeze
      KEYS = %w[
        schema schema_version attempt_id plan_digest policy_fingerprint outcome findings coverage
        selected_lenses residual_evidence diagnostic retry_at
      ].freeze

      Parsed = Data.define(
        :attempt_id, :plan_digest, :policy_fingerprint, :outcome, :findings,
        :coverage, :selected_lenses, :residual_evidence, :diagnostic, :retry_at
      ) do
        def to_h
          {
            "schema" => ResultParser::SCHEMA,
            "schema_version" => ResultParser::SCHEMA_VERSION,
            "attempt_id" => attempt_id,
            "plan_digest" => plan_digest,
            "policy_fingerprint" => policy_fingerprint,
            "outcome" => outcome,
            "findings" => findings.map(&:to_h),
            "coverage" => coverage,
            "selected_lenses" => selected_lenses,
            "residual_evidence" => residual_evidence,
            "diagnostic" => diagnostic,
            "retry_at" => retry_at
          }
        end
      end

      module_function

      def parse(bytes, expected: nil, snapshot_bytes: nil)
        raw = bytes.to_s
        raise InvalidRecord, "plan review result exceeds the size limit" if raw.bytesize > MAX_BYTES
        raise InvalidRecord, "plan review result is not valid UTF-8" unless raw.dup.force_encoding(Encoding::UTF_8).valid_encoding?

        data = JSON.parse(raw)
        raise InvalidRecord, "plan review result must be a JSON object" unless data.is_a?(Hash)
        unknown = data.keys - KEYS
        missing = %w[
          schema schema_version attempt_id plan_digest policy_fingerprint outcome findings coverage
          selected_lenses residual_evidence diagnostic
        ] - data.keys
        raise InvalidRecord, "plan review result has unknown fields: #{unknown.sort.join(', ')}" unless unknown.empty?
        raise InvalidRecord, "plan review result is missing fields: #{missing.join(', ')}" unless missing.empty?
        unless data["schema"] == SCHEMA && data["schema_version"] == SCHEMA_VERSION
          raise InvalidRecord, "invalid plan review adapter result envelope"
        end
        raise InvalidRecord, "unknown plan review result outcome" unless OUTCOMES.include?(data["outcome"])
        validate_identity!(data)
        validate_expected!(data, expected) if expected

        findings = Array(data["findings"]).map { |entry| Finding.build(entry) }
        validate_finding_anchors!(findings, snapshot_bytes) if snapshot_bytes
        coverage = validate_coverage!(data["coverage"])
        lenses = validate_names!(data["selected_lenses"], "selected_lenses")
        residual = validate_residual_evidence!(data["residual_evidence"])
        diagnostic = data["diagnostic"]
        unless diagnostic.nil? || diagnostic.is_a?(String)
          raise InvalidRecord, "plan review diagnostic must be a String or null"
        end
        retry_at = data["retry_at"]
        validate_retry_at!(retry_at, "retry_at") if retry_at

        Parsed.new(
          attempt_id: data["attempt_id"].freeze,
          plan_digest: data["plan_digest"].freeze,
          policy_fingerprint: data["policy_fingerprint"].freeze,
          outcome: data["outcome"].freeze,
          findings: findings.freeze,
          coverage: coverage.freeze,
          selected_lenses: lenses.freeze,
          residual_evidence: residual.freeze,
          diagnostic: diagnostic&.freeze,
          retry_at: retry_at&.freeze
        ).freeze
      rescue JSON::ParserError => e
        raise InvalidRecord, "plan review result is not valid JSON: #{e.message}"
      end

      def validate_identity!(data)
        unless data["attempt_id"].to_s.match?(/\Apra-[0-9a-f]{64}\z/) &&
               data["plan_digest"].to_s.match?(Record::DIGEST) &&
               data["policy_fingerprint"].to_s.match?(Record::DIGEST)
          raise InvalidRecord, "plan review result identity is malformed"
        end
      end

      def validate_expected!(data, expected)
        expected.each do |key, value|
          next if data[key.to_s] == value

          raise StaleObservation, "plan review result #{key} does not match its request"
        end
      end

      def validate_finding_anchors!(findings, snapshot_bytes)
        text = snapshot_bytes.to_s.dup.force_encoding(Encoding::UTF_8)
        raise InvalidRecord, "plan review snapshot is not valid UTF-8" unless text.valid_encoding?

        lines = text.lines(chomp: true)
        findings.each do |finding|
          evidence = finding["evidence"]
          unless evidence.fetch("path") == "plan.md"
            raise InvalidRecord, "finding evidence path must reference the immutable plan snapshot"
          end
          start_line = evidence.fetch("start_line")
          end_line = evidence.fetch("end_line")
          anchored = lines[(start_line - 1)..(end_line - 1)]
          if anchored.nil? || anchored.length != end_line - start_line + 1
            raise InvalidRecord, "finding evidence line range is outside the immutable plan snapshot"
          end
          digest = Digest::SHA256.hexdigest(anchored.join("\n").b)
          unless digest == evidence.fetch("anchor_digest")
            raise InvalidRecord, "finding evidence anchor does not match the immutable plan snapshot"
          end
        end
      end

      def validate_coverage!(value)
        raise InvalidRecord, "plan review coverage must be an Array" unless value.is_a?(Array)
        names = Set.new
        value.map do |entry|
          unless entry.is_a?(Hash) && (entry.keys - %w[name required status reason retry_at]).empty? &&
                 entry["name"].to_s.match?(/\A[a-z][a-z0-9_]{0,63}\z/) &&
                 (entry["required"] == true || entry["required"] == false) &&
                 Record::COVERAGE_STATUSES.include?(entry["status"])
            raise InvalidRecord, "invalid plan review coverage entry"
          end
          raise InvalidRecord, "duplicate plan review coverage item" unless names.add?(entry["name"])

          validate_retry_at!(entry["retry_at"], "coverage retry_at") if entry["retry_at"]
          Hive::PlanReview.deep_freeze(entry)
        end
      end

      def validate_names!(value, label)
        unless value.is_a?(Array) &&
               value.all? { |name| name.is_a?(String) && name.match?(LENS_NAME) }
          raise InvalidRecord,
                "plan review #{label} must contain lowercase names of 1-64 characters that " \
                "start with a letter and use only lowercase letters, digits, hyphens, or underscores"
        end
        value.uniq
      end

      def recoverable_selected_lenses_routes(routes)
        recoverable_parser_contract_routes(
          routes,
          diagnostic: LEGACY_SELECTED_LENSES_DIAGNOSTIC,
          recovery_flag: "selected_lenses_contract_recovery",
          version_field: "selected_lenses_contract_version",
          version: SELECTED_LENSES_CONTRACT_VERSION
        )
      end

      def recoverable_residual_evidence_routes(routes)
        recoverable_parser_contract_routes(
          routes,
          diagnostic: LEGACY_RESIDUAL_EVIDENCE_DIAGNOSTIC,
          recovery_flag: "residual_evidence_contract_recovery",
          version_field: "residual_evidence_contract_version",
          version: RESIDUAL_EVIDENCE_CONTRACT_VERSION
        )
      end

      def recoverable_parser_contract_routes(routes, diagnostic:, recovery_flag:,
                                              version_field:, version:)
        recoverable = {}
        recovered_roles = Set.new
        Array(routes).reverse_each do |route|
          role = route["role"]
          next unless INITIAL_REVIEW_RECOVERY_ROLES.include?(role)

          if current_parser_contract?(
            route, recovery_flag:, version_field:, version:
          )
            recovered_roles.add(role)
            recoverable.delete(role)
          elsif !recovered_roles.include?(role) && !recoverable.key?(role) &&
                route["outcome"] == "terminal_failure" &&
                route["diagnostic"] == diagnostic &&
                [ nil, "parser" ].include?(route["diagnostic_source"])
            recoverable[role] = route
          end
        end
        recoverable.values
      end
      private_class_method :recoverable_parser_contract_routes

      def current_parser_contract?(route, recovery_flag:, version_field:, version:)
        route[recovery_flag] == true && Integer(route[version_field]) >= version
      rescue ArgumentError, TypeError
        false
      end
      private_class_method :current_parser_contract?

      def validate_residual_evidence!(value)
        raise InvalidRecord, "residual_evidence must be an Array" unless value.is_a?(Array)

        seen = Set.new
        value.map do |entry|
          unless entry.is_a?(Hash) &&
                 entry.keys.sort == %w[evidence finding_fingerprint status] &&
                 entry["finding_fingerprint"].to_s.match?(Record::FINDING_ID) &&
                 entry["status"] == "verified" &&
                 entry["evidence"].is_a?(String) && !entry["evidence"].strip.empty?
            raise InvalidRecord, "invalid plan review residual evidence entry"
          end
          unless seen.add?(entry["finding_fingerprint"])
            raise InvalidRecord, "duplicate plan review residual evidence item"
          end

          Hive::PlanReview.deep_freeze(entry)
        end
      end

      def validate_retry_at!(value, label)
        unless value.is_a?(String)
          raise InvalidRecord, "plan review #{label} must be a timestamp String"
        end
        Time.iso8601(value)
      rescue ArgumentError
        raise InvalidRecord, "plan review #{label} must be ISO-8601"
      end
    end
  end
end
