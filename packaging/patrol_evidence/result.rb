# frozen_string_literal: true

require "json"
require "time"
require_relative "../../lib/hive/secret_patterns"

module HivePatrolEvidence
  # The closed, secret-free result vocabulary for the reduced U3c smoke.
  class Result
    class Error < StandardError; end

    SCHEMA = "hive-patrol-installed-live-smoke"
    SCHEMA_VERSION = 1
    MAX_RESULT_BYTES = 512 * 1024
    CLAIM_FENCES = %w[
      not_full_u3b
      prepared_records_not_fresh_scheduler_matrix
      controller_does_not_supply_full_independent_matrix
      not_report_installed_live_qualification
      provider_probe_not_patrol_decision
      not_evidence_ready_for_operator
      not_cutover_or_promotion_authority
    ].freeze
    SAME_USER_LIMITATION = "same_user_host_processes_are_outside_the_sandbox_claim".freeze
    TERMINAL_STATUSES = %w[installed_live_smoke_verified blocked failed].freeze
    REASONS = %w[
      manual_authority_missing sandbox_unavailable installed_dependency_missing
      credential_unavailable provider_unavailable evidence_store_full
      candidate_identity candidate_archive runtime_identity path_custody sandbox_contract
      process_custody credential_custody provider_transport effect_forbidden
      authority_binding input_bound output_bound publication_conflict evidence_custody
      smoke_validation unexpected_failure
    ].freeze
    AUTHORITY_KEYS = %w[
      authorization_sha256 candidate_sha controller_script_sha256 controller_sha
      invocation_id run_id runner_sha256
    ].freeze

    class << self
      def not_started(authority:, started_at:)
        build(
          status: "not_started", reason: nil, authority:, candidate: nil, sandbox: nil,
          smoke: nil, provider: nil, process_evidence: [], started_at:, finished_at: nil
        )
      end

      def terminal(status:, reason:, authority:, candidate:, sandbox:, smoke:, provider:,
                   process_evidence:, started_at:, finished_at:, exact_secrets: [])
        build(
          status:, reason:, authority:, candidate:, sandbox:, smoke:, provider:,
          process_evidence:, started_at:, finished_at:, exact_secrets:
        )
      end

      def canonical(value)
        JSON.generate(canonical_value(value)) + "\n"
      rescue JSON::GeneratorError, TypeError
        raise Error, "patrol smoke result is not canonical JSON", cause: nil
      end

      private

      def build(status:, reason:, authority:, candidate:, sandbox:, smoke:, provider:,
                process_evidence:, started_at:, finished_at:, exact_secrets: [])
        validate_status!(status, reason)
        validate_authority!(authority)
        validate_time!(started_at, "started_at")
        validate_time!(finished_at, "finished_at") if finished_at
        raise Error, "patrol smoke process evidence is malformed" unless process_evidence.is_a?(Array)

        document = {
          "schema" => SCHEMA,
          "schema_version" => SCHEMA_VERSION,
          "status" => status,
          "reason" => reason,
          "claim_fences" => CLAIM_FENCES,
          "same_user_limitation" => SAME_USER_LIMITATION,
          "authority" => authority,
          "candidate" => candidate,
          "sandbox" => sandbox,
          "smoke" => smoke,
          "provider" => provider,
          "process_evidence" => process_evidence,
          "started_at" => started_at,
          "finished_at" => finished_at
        }
        bytes = canonical(document)
        raise Error, "patrol smoke result exceeds its byte bound" if bytes.bytesize > MAX_RESULT_BYTES
        reject_secrets!(bytes, exact_secrets)
        new(deep_freeze(canonical_value(document)), bytes.freeze)
      rescue KeyError, NoMethodError, TypeError
        raise Error, "patrol smoke result is malformed", cause: nil
      end

      def validate_status!(status, reason)
        valid = if status == "not_started"
          reason.nil?
        elsif status == "installed_live_smoke_verified"
          reason.nil?
        else
          TERMINAL_STATUSES.include?(status) && REASONS.include?(reason)
        end
        raise Error, "patrol smoke status or reason is unsupported" unless valid
      end

      def validate_authority!(authority)
        valid = authority.is_a?(Hash) && authority.keys.sort == AUTHORITY_KEYS &&
          authority.values_at("controller_sha", "candidate_sha").all? do |sha|
            sha.is_a?(String) && sha.match?(/\A[0-9a-f]{40}\z/)
          end && authority.values_at("runner_sha256", "controller_script_sha256",
                                     "authorization_sha256").all? do |digest|
            digest.is_a?(String) && digest.match?(/\A[0-9a-f]{64}\z/)
          end && authority.values_at("run_id", "invocation_id").all? do |value|
            value.is_a?(String) && value.match?(/\A[A-Za-z0-9][A-Za-z0-9._-]{0,127}\z/)
          end
        raise Error, "patrol smoke authority binding is malformed" unless valid
        raise Error, "controller and candidate SHAs must be distinct" if
          authority.fetch("controller_sha") == authority.fetch("candidate_sha")
      end

      def validate_time!(value, label)
        parsed = Time.iso8601(value.to_s)
        raise Error, "#{label} must be UTC" unless parsed.utc_offset.zero?
      rescue ArgumentError
        raise Error, "#{label} is malformed", cause: nil
      end

      def reject_secrets!(bytes, exact_secrets)
        secrets = Array(exact_secrets).compact.map(&:to_s).reject(&:empty?)
        leaked = secrets.any? { |secret| bytes.include?(secret) }
        leaked ||= Hive::SecretPatterns.match?(bytes)
        raise Error, "patrol smoke result contains credential-shaped bytes" if leaked
      end

      def canonical_value(value)
        case value
        when Hash
          raise Error, "patrol smoke result keys must be strings" unless value.keys.all?(String)
          value.keys.sort.to_h { |key| [ key, canonical_value(value.fetch(key)) ] }
        when Array then value.map { |item| canonical_value(item) }
        when String, Integer, TrueClass, FalseClass, NilClass then value
        else raise Error, "patrol smoke result contains an unsupported value"
        end
      end

      def deep_freeze(value)
        case value
        when Hash
          value.each { |key, item| key.freeze; deep_freeze(item) }
        when Array then value.each { |item| deep_freeze(item) }
        end
        value.freeze
      end
    end

    attr_reader :canonical_bytes

    def initialize(document, canonical_bytes)
      @document = document
      @canonical_bytes = canonical_bytes
      freeze
    end
    private_class_method :new

    def to_h = @document
  end
end
