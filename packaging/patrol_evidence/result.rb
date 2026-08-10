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
      authorization_expires_at authorization_nonce_sha256 authorization_sha256 candidate_sha
      control_tree_sha256 controller_script_sha256 controller_sha image invocation_id
      observations_sha256 project_binding_sha256 run_id runner_sha256
    ].freeze
    CANDIDATE_PREPARED_KEYS = %w[
      archive_member_count archive_sha256 archive_total_bytes candidate_sha
      module_manifest_sha256 source_tree_sha256 status
    ].freeze
    CANDIDATE_VERIFIED_KEYS = %w[
      archive_member_count archive_sha256 archive_total_bytes candidate_sha
      dependency_closure_sha256 gem_sha256 installed_hive_sha256 module_manifest_sha256
      source_tree_sha256 status toolchain_sha256
    ].freeze
    SANDBOX_KEYS = %w[
      cpus engine engine_sha256 engine_version image image_id memory network process_limit
      root_filesystem status writable_bytes writable_inodes
    ].freeze
    SMOKE_KEYS = %w[
      catalog_digest modules receipt_count report_sha256 scenario_manifest_digest status
    ].freeze
    PROVIDER_KEYS = %w[model provider response_sha256 status usage].freeze
    PROCESS_KEYS = %w[
      container_id_sha256 exit_code outcome owner status stderr_sha256 stdout_sha256 teardown
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
        validate_records!(status, candidate:, sandbox:, smoke:, provider:, process_evidence:)
        validate_cross_fields!(status, candidate:, sandbox:, smoke:, provider:, process_evidence:, finished_at:)

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
          end && authority.values_at(
            "runner_sha256", "controller_script_sha256", "control_tree_sha256",
            "authorization_sha256", "authorization_nonce_sha256", "observations_sha256",
            "project_binding_sha256"
          ).all? do |digest|
            digest.is_a?(String) && digest.match?(/\A[0-9a-f]{64}\z/)
          end && authority.values_at("run_id", "invocation_id").all? do |value|
            value.is_a?(String) && value.match?(/\A[A-Za-z0-9][A-Za-z0-9._-]{0,127}\z/)
          end && authority.fetch("image").is_a?(String) &&
          authority.fetch("image").match?(/\A[a-z0-9][a-z0-9._\/-]*@sha256:[0-9a-f]{64}\z/) &&
          utc_time?(authority.fetch("authorization_expires_at"))
        raise Error, "patrol smoke authority binding is malformed" unless valid
        raise Error, "controller and candidate SHAs must be distinct" if
          authority.fetch("controller_sha") == authority.fetch("candidate_sha")
      end

      def validate_records!(status, candidate:, sandbox:, smoke:, provider:, process_evidence:)
        raise Error, "patrol smoke process evidence is malformed" unless
          process_evidence.is_a?(Array) && process_evidence.size <= 1
        process_evidence.each { |row| validate_process!(row) }
        validate_candidate!(candidate) if candidate
        validate_sandbox!(sandbox) if sandbox
        validate_smoke!(smoke) if smoke
        validate_provider!(provider) if provider

        return unless status == "installed_live_smoke_verified"

        valid = candidate&.fetch("status", nil) == "verified" && sandbox&.fetch("status", nil) == "passed" &&
          smoke&.fetch("status", nil) == "passed" && provider&.fetch("status", nil) == "passed" &&
          process_evidence.one? && process_evidence.dig(0, "status") == "reaped" &&
          process_evidence.dig(0, "outcome") == "success" &&
          process_evidence.dig(0, "teardown") == "verified" &&
          process_evidence.dig(0, "exit_code") == 0
        raise Error, "verified patrol smoke is missing closed success evidence" unless valid
      rescue KeyError, NoMethodError, TypeError
        raise Error, "patrol smoke component evidence is malformed", cause: nil
      end

      def validate_cross_fields!(status, candidate:, sandbox:, smoke:, provider:, process_evidence:, finished_at:)
        if status == "not_started"
          valid = [ candidate, sandbox, smoke, provider, finished_at ].all?(&:nil?) && process_evidence.empty?
        else
          valid = !finished_at.nil?
        end
        raise Error, "patrol smoke status fields are inconsistent" unless valid
      end

      def validate_candidate!(value)
        keys = value.fetch("status") == "prepared" ? CANDIDATE_PREPARED_KEYS : CANDIDATE_VERIFIED_KEYS
        valid = value.is_a?(Hash) && %w[prepared verified].include?(value.fetch("status")) &&
          value.keys.sort == keys &&
          %w[candidate_sha].all? { |key| value.fetch(key).to_s.match?(/\A[0-9a-f]{40}\z/) } &&
          %w[archive_sha256 module_manifest_sha256 source_tree_sha256].all? do |key|
            value.fetch(key).to_s.match?(/\A[0-9a-f]{64}\z/)
          end && value.fetch("archive_member_count").is_a?(Integer) &&
          value.fetch("archive_member_count").positive? &&
          value.fetch("archive_total_bytes").is_a?(Integer) && value.fetch("archive_total_bytes").positive?
        if value.fetch("status") == "verified"
          valid &&= %w[
            dependency_closure_sha256 gem_sha256 installed_hive_sha256 toolchain_sha256
          ].all? { |key| value.fetch(key).to_s.match?(/\A[0-9a-f]{64}\z/) }
        end
        raise Error, "patrol smoke candidate evidence is malformed" unless valid
      end

      def validate_sandbox!(value)
        valid = value.is_a?(Hash) && value.keys.sort == SANDBOX_KEYS && value.fetch("status") == "passed" &&
          %w[docker podman].include?(value.fetch("engine")) &&
          value.fetch("engine_version").is_a?(String) && !value.fetch("engine_version").empty? &&
          value.values_at("engine_sha256").all? { |item| item.to_s.match?(/\A[0-9a-f]{64}\z/) } &&
          value.fetch("image").to_s.match?(/@sha256:[0-9a-f]{64}\z/) &&
          value.fetch("image_id").to_s.match?(/\Asha256:[0-9a-f]{64}\z/) &&
          value.values_at("network", "root_filesystem", "memory", "cpus") ==
            %w[none read_only 2g 2] &&
          value.fetch("process_limit").is_a?(Integer) && value.fetch("process_limit").positive? &&
          value.fetch("writable_bytes").is_a?(Integer) && value.fetch("writable_bytes").positive? &&
          value.fetch("writable_inodes").is_a?(Integer) && value.fetch("writable_inodes").positive?
        raise Error, "patrol smoke sandbox evidence is malformed" unless valid
      end

      def validate_smoke!(value)
        valid = value.is_a?(Hash) && value.keys.sort == SMOKE_KEYS && value.fetch("status") == "passed" &&
          value.fetch("modules") == %w[architecture-patrol patrol] &&
          value.fetch("receipt_count").is_a?(Integer) && value.fetch("receipt_count").positive? &&
          %w[catalog_digest report_sha256 scenario_manifest_digest].all? do |key|
            value.fetch(key).to_s.match?(/\A[0-9a-f]{64}\z/)
          end
        raise Error, "patrol smoke controller evidence is malformed" unless valid
      end

      def validate_provider!(value)
        usage = value.fetch("usage")
        valid = value.is_a?(Hash) && value.keys.sort == PROVIDER_KEYS && value.fetch("status") == "passed" &&
          value.values_at("provider", "model") == [ "openrouter", "openai/gpt-5.6-terra" ] &&
          value.fetch("response_sha256").to_s.match?(/\A[0-9a-f]{64}\z/) &&
          usage.is_a?(Hash) && usage.keys.sort == %w[completion_tokens prompt_tokens total_tokens] &&
          usage.values.all? { |item| item.is_a?(Integer) && item.positive? } &&
          usage.fetch("total_tokens") >= usage.fetch("prompt_tokens") + usage.fetch("completion_tokens")
        raise Error, "patrol smoke provider evidence is malformed" unless valid
      end

      def validate_process!(value)
        valid = value.is_a?(Hash) && value.keys.sort == PROCESS_KEYS && value.fetch("owner") == "sandbox" &&
          %w[reaped not_reaped].include?(value.fetch("status")) &&
          %w[success failed timeout interrupted unavailable].include?(value.fetch("outcome")) &&
          %w[verified unverified].include?(value.fetch("teardown")) &&
          [ nil, Integer ].any? { |type| type.nil? ? value.fetch("exit_code").nil? : value.fetch("exit_code").is_a?(type) } &&
          [ nil, value.fetch("container_id_sha256") ].compact.all? do |digest|
            digest.to_s.match?(/\A[0-9a-f]{64}\z/)
          end && %w[stdout_sha256 stderr_sha256].all? do |key|
            value.fetch(key).to_s.match?(/\A[0-9a-f]{64}\z/)
          end
        raise Error, "patrol smoke process evidence is malformed" unless valid
      end

      def utc_time?(value)
        Time.iso8601(value.to_s).utc_offset.zero?
      rescue ArgumentError
        false
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
