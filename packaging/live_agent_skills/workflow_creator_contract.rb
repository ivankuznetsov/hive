# frozen_string_literal: true

require_relative "proof_primitives"

module HiveLiveAgentProof
  class WorkflowCreatorContract
    KEYS = %w[
      schema schema_version platform candidate_sha result prompt_sha256
      task_prompt_sha256 skill native_activation hive_commands created_files
      validation creation_only_task_count task_count task external_actions
      secret_scan cleanup execution_kind model_loop executed_instruction
      evidence_bundle containment teardown
    ].freeze
    MANIFEST_KEYS = %w[
      canonical_digest candidate_sha files hive_version schema schema_version
      skill_version
    ].freeze
    FILE_KEYS = %w[path sha256 size].freeze
    SUMMARY_KEYS = %w[receipt_sha256 status].freeze
    BUNDLE_KEYS = %w[kind path sha256 size].freeze
    FAILURE_KEYS = %w[
      schema schema_version platform candidate_sha result phase reason detail
      execution_kind model_loop secret_scan
    ].freeze
    FAILURE_PART = /\A[a-z][a-z0-9_]{0,63}\z/.freeze
    CLASSIFICATIONS = [
      %w[unavailable not_started].freeze,
      %w[deterministic_fixture not_exercised].freeze,
      %w[authenticated_openclaw executed].freeze
    ].freeze
    DETAIL_LIMIT = 1_000
    class << self
      def failure(candidate_sha:, phase:, reason:, detail: nil,
                  execution_kind: "unavailable", model_loop: "not_started",
                  exact_secrets: [])
        bounded = detail.nil? ? nil : detail.to_s.encode(
          Encoding::UTF_8, invalid: :replace, undef: :replace, replace: "\uFFFD"
        )
        exact_secrets.map do |secret|
          secret.to_s.encode(
            Encoding::UTF_8, invalid: :replace, undef: :replace, replace: "\uFFFD"
          )
        end.reject(&:empty?).each do |secret|
          bounded&.gsub!(secret, "[REDACTED]")
        end
        SECRET_PATTERNS.each { |pattern| bounded&.gsub!(pattern, "[REDACTED]") }
        bounded = bounded&.byteslice(0, DETAIL_LIMIT)&.force_encoding(Encoding::UTF_8)&.scrub("")
        document = {
          "schema" => WORKFLOW_CREATOR_EVIDENCE_SCHEMA,
          "schema_version" => SCHEMA_VERSION,
          "platform" => "openclaw",
          "candidate_sha" => SAFE_SHA.match?(candidate_sha.to_s.downcase) ? candidate_sha.to_s.downcase : "unresolved",
          "result" => "failed",
          "phase" => phase.to_s,
          "reason" => reason.to_s,
          "detail" => bounded,
          "execution_kind" => execution_kind.to_s,
          "model_loop" => model_loop.to_s,
          "secret_scan" => {
            "status" => "passed", "scanner" => WORKFLOW_CREATOR_SCANNER
          }
        }
        validate_nonpassing!(document)
      end

      def validate_nonpassing!(row)
        exact!(row, FAILURE_KEYS, "workflow-creator non-passing evidence")
        exact!(row["secret_scan"], %w[scanner status], "workflow-creator non-passing secret scan")
        valid =
          row["schema"] == WORKFLOW_CREATOR_EVIDENCE_SCHEMA &&
          row["schema_version"].is_a?(Integer) && row["schema_version"] == SCHEMA_VERSION &&
          row["platform"] == "openclaw" &&
          row["candidate_sha"].is_a?(String) &&
          (row["candidate_sha"] == "unresolved" || SAFE_SHA.match?(row["candidate_sha"]))
        valid &&=
          row["result"] == "failed" && row["phase"].is_a?(String) &&
          FAILURE_PART.match?(row["phase"]) && row["reason"].is_a?(String) &&
          FAILURE_PART.match?(row["reason"]) &&
          (row["detail"].nil? || (row["detail"].is_a?(String) && row["detail"].bytesize <= DETAIL_LIMIT)) &&
          CLASSIFICATIONS.include?([ row["execution_kind"], row["model_loop"] ]) &&
          row["secret_scan"] == { "status" => "passed", "scanner" => WORKFLOW_CREATOR_SCANNER }
        assert!(valid, "workflow-creator non-passing evidence is invalid")
        findings = HiveLiveAgentProof.secret_findings(JSON.generate(row))
        assert!(findings.empty?, "workflow-creator non-passing evidence contains secret-shaped material")
        row
      rescue TypeError, NoMethodError, ArgumentError, JSON::GeneratorError
        raise Error, "workflow-creator non-passing evidence is invalid"
      end

      def validate!(row:, manifest:, candidate_sha:, bundle_records:)
        exact!(row, KEYS, "workflow-creator evidence")
        validate_identity!(row, manifest, candidate_sha, bundle_records)
        validate_content!(row, bundle_records.fetch(2).fetch("sha256"))
        findings = HiveLiveAgentProof.secret_findings(JSON.generate(row))
        assert!(findings.empty?, "workflow-creator evidence contains secret-shaped material")
        row
      rescue KeyError, TypeError, NoMethodError, ArgumentError, JSON::GeneratorError
        raise Error, "workflow-creator contract is invalid"
      end

      private

      def validate_identity!(row, manifest, candidate_sha, bundle_records)
        exact!(manifest, MANIFEST_KEYS, "artifact manifest")
        exact!(row["skill"], %w[canonical_digest skill_version], "workflow-creator skill")
        exact!(row["native_activation"], %w[invocation kind], "workflow-creator activation")
        exact!(row["secret_scan"], %w[scanner status], "workflow-creator secret scan")
        bundle_records.each { |record| exact!(record, BUNDLE_KEYS, "workflow-creator bundle record") }
        expected = {
          "schema" => WORKFLOW_CREATOR_EVIDENCE_SCHEMA,
          "schema_version" => SCHEMA_VERSION,
          "platform" => "openclaw",
          "candidate_sha" => candidate_sha,
          "result" => "passed",
          "skill" => {
            "skill_version" => manifest["skill_version"],
            "canonical_digest" => manifest["canonical_digest"]
          },
          "native_activation" => WORKFLOW_CREATOR_NATIVE_ACTIVATION,
          "secret_scan" => {
            "status" => "passed", "scanner" => WORKFLOW_CREATOR_SCANNER
          },
          "execution_kind" => WORKFLOW_CREATOR_CLASSIFICATION["execution_kind"],
          "model_loop" => WORKFLOW_CREATOR_CLASSIFICATION["model_loop"]
        }
        manifest_valid =
          manifest["schema"] == "hive-live-agent-candidate-artifacts" &&
          manifest["schema_version"].is_a?(Integer) &&
          manifest["schema_version"] == SCHEMA_VERSION &&
          manifest["candidate_sha"] == candidate_sha &&
          manifest["files"].is_a?(Hash) &&
          manifest["files"].values.all? { |record| record["size"].is_a?(Integer) } &&
          manifest["hive_version"].is_a?(String) && !manifest["hive_version"].empty? &&
          manifest["skill_version"].is_a?(String) && !manifest["skill_version"].empty? &&
          manifest["canonical_digest"].is_a?(String) &&
          SAFE_DIGEST.match?(manifest["canonical_digest"])
        assert!(
          candidate_sha.is_a?(String) && SAFE_SHA.match?(candidate_sha) && manifest_valid &&
            row["schema_version"].is_a?(Integer) &&
            expected.all? { |key, value| row[key] == value } &&
            HiveLiveAgentProof.canonical_json(row["evidence_bundle"]) ==
              HiveLiveAgentProof.canonical_json(bundle_records),
          "workflow-creator evidence identity or result is invalid"
        )
      end

      def validate_content!(row, receipt_sha256)
        created = row["created_files"]
        assert!(
          created.is_a?(Array) &&
            created.map { |record| record["path"] } == WORKFLOW_CREATOR_FILES &&
            created.all? { |record| valid_file_record?(record) },
          "workflow-creator created-file records are invalid"
        )
        authored = created.find do |record|
          record["path"] == WORKFLOW_CREATOR_EXECUTED_INSTRUCTION
        end
        assert!(
          valid_file_record?(row["executed_instruction"]) &&
            row["executed_instruction"] == authored,
          "workflow-creator authored and executed instructions do not match"
        )
        assert!(row["validation"] == WORKFLOW_CREATOR_GRAPH, "workflow-creator normalized graph is invalid")
        task_valid =
          row["creation_only_task_count"].is_a?(Integer) &&
          row["task_count"].is_a?(Integer) && row.dig("task", "run_count").is_a?(Integer) &&
          row["creation_only_task_count"] == 0 && row["task_count"] == 1 &&
          row["task"] == WORKFLOW_CREATOR_TASK && row["external_actions"] == []
        assert!(task_valid, "workflow-creator proof contains an unauthorized side effect")
        prompt_valid =
          row["prompt_sha256"] == Digest::SHA256.hexdigest(WORKFLOW_CREATOR_PROMPT) &&
          row["task_prompt_sha256"] == Digest::SHA256.hexdigest(WORKFLOW_CREATOR_TASK_PROMPT) &&
          row["hive_commands"] == WORKFLOW_CREATOR_COMMANDS
        assert!(prompt_valid, "workflow-creator prompt or command sequence is invalid")
        expected = { "status" => "passed", "receipt_sha256" => receipt_sha256 }
        %w[containment teardown cleanup].each do |field|
          exact!(row[field], SUMMARY_KEYS, "workflow-creator #{field}")
          assert!(row[field] == expected, "workflow-creator execution claims are not passing")
        end
      end

      def valid_file_record?(record)
        record.is_a?(Hash) && record.keys.sort == FILE_KEYS &&
          HiveLiveAgentProof.safe_relative_path?(record["path"]) &&
          record["sha256"].is_a?(String) && SAFE_DIGEST.match?(record["sha256"]) &&
          record["size"].is_a?(Integer) && record["size"].positive?
      end

      def exact!(value, keys, label)
        assert!(value.is_a?(Hash) && value.keys.sort == keys.sort, "#{label} fields are invalid")
      end

      def assert!(condition, message)
        raise Error, message unless condition
      end
    end
  end
end
