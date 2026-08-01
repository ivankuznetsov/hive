# frozen_string_literal: true

require_relative "proof_primitives"

module HiveLiveAgentProof
  class WorkflowCreatorExecutionContract
    KEYS = %w[
      schema schema_version candidate_sha result execution_plan classification
      installed_manifests prompt_sha256 hive_commands_sha256 authored_instruction
      executed_instruction external_actions containment teardown cleanup secret_scan
    ].freeze
    BUNDLE_KEYS = %w[kind path sha256 size].freeze
    FILE_KEYS = %w[path sha256 size].freeze
    STATUS_KEYS = %w[status].freeze
    class << self
      def validate!(receipt:, row:, candidate_sha:, installation_records:, receipt_sha256:)
        exact!(receipt, KEYS, "execution receipt")
        validate_identity!(receipt, candidate_sha, installation_records)
        validate_bindings!(receipt, row, receipt_sha256)
        findings = HiveLiveAgentProof.secret_findings(JSON.generate(receipt))
        fail_contract!("execution receipt contains secret-shaped material") unless findings.empty?
        receipt
      rescue KeyError, TypeError, NoMethodError, ArgumentError, JSON::GeneratorError
        fail_contract!("execution receipt is invalid")
      end

      private

      def validate_identity!(receipt, candidate_sha, installation_records)
        exact!(receipt["classification"], %w[execution_kind model_loop], "execution classification")
        exact!(receipt["secret_scan"], %w[scanner status], "execution secret scan")
        installation_records.each { |record| exact!(record, BUNDLE_KEYS, "installed manifest record") }
        valid =
          receipt["schema"] == WORKFLOW_CREATOR_EXECUTION_SCHEMA &&
          receipt["schema_version"] == SCHEMA_VERSION &&
          receipt["candidate_sha"] == candidate_sha &&
          receipt["result"] == "passed" &&
          receipt["execution_plan"] == WORKFLOW_CREATOR_EXECUTION_PLAN &&
          receipt["classification"] == WORKFLOW_CREATOR_CLASSIFICATION &&
          receipt["installed_manifests"] == installation_records &&
          receipt["prompt_sha256"] == [
            Digest::SHA256.hexdigest(WORKFLOW_CREATOR_PROMPT),
            Digest::SHA256.hexdigest(WORKFLOW_CREATOR_TASK_PROMPT)
          ] &&
          receipt["hive_commands_sha256"] ==
            Digest::SHA256.hexdigest(HiveLiveAgentProof.canonical_json(WORKFLOW_CREATOR_COMMANDS)) &&
          receipt["secret_scan"] == {
            "status" => "passed", "scanner" => WORKFLOW_CREATOR_SCANNER
          }
        fail_contract!("execution receipt identity is invalid") unless valid
      end

      def validate_bindings!(receipt, row, receipt_sha256)
        file_record!(receipt["authored_instruction"])
        file_record!(receipt["executed_instruction"])
        %w[containment teardown cleanup].each do |field|
          exact!(receipt[field], STATUS_KEYS, "execution #{field}")
        end
        summary = { "status" => "passed", "receipt_sha256" => receipt_sha256 }
        valid =
          receipt_sha256.is_a?(String) && SAFE_DIGEST.match?(receipt_sha256) &&
          receipt["authored_instruction"] == receipt["executed_instruction"] &&
          receipt["executed_instruction"] == row["executed_instruction"] &&
          receipt["external_actions"] == row["external_actions"] &&
          receipt["classification"] == row.slice("execution_kind", "model_loop") &&
          %w[containment teardown cleanup].all? do |field|
            receipt[field] == { "status" => "passed" } && row[field] == summary
          end
        fail_contract!("execution receipt bindings are inconsistent") unless valid
      end

      def file_record!(record)
        valid = record.is_a?(Hash) && record.keys.sort == FILE_KEYS &&
          HiveLiveAgentProof.safe_relative_path?(record["path"]) &&
          record["sha256"].is_a?(String) && SAFE_DIGEST.match?(record["sha256"]) &&
          record["size"].is_a?(Integer) && record["size"].positive?
        fail_contract!("execution instruction record is invalid") unless valid
      end

      def exact!(value, keys, label)
        fail_contract!("#{label} fields are invalid") unless value.is_a?(Hash) && value.keys.sort == keys.sort
      end

      def fail_contract!(message)
        raise Error, "workflow-creator #{message}"
      end
    end
  end
end
