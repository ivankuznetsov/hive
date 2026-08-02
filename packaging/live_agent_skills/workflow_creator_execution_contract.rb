# frozen_string_literal: true

require_relative "proof_primitives"

module HiveLiveAgentProof
  class WorkflowCreatorExecutionContract
    KEYS = %w[schema schema_version candidate_sha result execution_plan classification installed_manifests run gateway
              archive_admissions commands outer_processes authored_instruction executed_instruction external_actions
              containment teardown cleanup secret_scan].freeze
    COMMAND_KEYS = %w[position attempt_label argv exit_code signal completed capture teardown].freeze
    OUTER_KEYS = %w[label role argv_sha256 prompt_sha256 exit_code signal completed capture teardown].freeze
    CAPTURE_KEYS = %w[limit_bytes stdout_bytes stderr_bytes stdout_sha256 stderr_sha256 stdout_truncated stderr_truncated secret_scan].freeze
    PROCESS_TEARDOWN_KEYS = %w[status term_sent kill_sent reaped descendants owner_complete].freeze
    ARCHIVE_KEYS = %w[label artifact_sha256 artifact_size policy_sha256 entry_count uncompressed_bytes status].freeze
    RUN_KEYS = %w[correlation_id expected_labels].freeze
    GATEWAY_KEYS = %w[identity command_labels status].freeze
    CONTAINMENT_KEYS = %w[status mechanism established_before_launch owner_correlation_id root_loss_behavior].freeze
    TEARDOWN_KEYS = %w[status expected_labels receipt_labels outer_root_reaped remaining_descendants].freeze
    CLEANUP_KEYS = %w[status targets].freeze
    TARGET_KEYS = %w[label path_sha256 device inode created_by_run identity_matched removed].freeze
    LABEL = /\A[a-z][a-z0-9_-]{0,127}\z/.freeze
    MAX_CAPTURE_BYTES = 1_048_576
    MAX_ARCHIVE_ENTRIES = 16_384
    MAX_ARCHIVE_BYTES = 1_073_741_824

    class << self
      def validate!(receipt:, row:, candidate_sha:, installation_records:,
                    receipt_sha256:, candidate_installation:, openclaw_installation:)
        exact!(receipt, KEYS, "execution receipt")
        validate_identity!(receipt, row, candidate_sha, installation_records,
                           candidate_installation, openclaw_installation)
        labels = validate_processes!(receipt)
        validate_aggregates!(receipt, row, labels, receipt_sha256)
        raise Error, "workflow-creator execution receipt contains secret-shaped material" unless
          HiveLiveAgentProof.secret_findings(JSON.generate(receipt)).empty?
        receipt
      rescue KeyError, TypeError, NoMethodError, ArgumentError, JSON::GeneratorError
        raise Error, "workflow-creator execution receipt is invalid"
      end

      private

      def validate_identity!(receipt, row, candidate_sha, installation_records,
                             candidate, openclaw)
        nested = { "execution_kind" => "deterministic_fixture", "model_loop" => "not_exercised" }
        expected_classification = { "outer" => row.slice("execution_kind", "model_loop"),
                                    "nested_stage" => nested }
        records_match = HiveLiveAgentProof.canonical_json(receipt["installed_manifests"]) == HiveLiveAgentProof.canonical_json(installation_records)
        exact!(receipt["gateway"], GATEWAY_KEYS, "execution gateway")
        valid =
          receipt["schema"] == WORKFLOW_CREATOR_EXECUTION_SCHEMA &&
          receipt["schema_version"].is_a?(Integer) &&
          receipt["schema_version"] == SCHEMA_VERSION &&
          receipt["candidate_sha"] == candidate_sha && receipt["result"] == "passed" &&
          receipt["execution_plan"] == WORKFLOW_CREATOR_EXECUTION_PLAN &&
          receipt["classification"] == expected_classification && records_match &&
          receipt["gateway"]["identity"] == candidate.fetch("required_roles").fetch("audit_gateway") &&
          receipt["gateway"]["status"] == "passed" &&
          receipt["secret_scan"] == { "status" => "passed", "scanner" => WORKFLOW_CREATOR_SCANNER }
        raise Error, "workflow-creator execution receipt identity is invalid" unless valid
        packages = [ candidate, openclaw ].map { |item| item.fetch("required_roles").fetch("package") }
        archives = receipt["archive_admissions"]
        archive_valid = archives.is_a?(Array) && archives.length == packages.length &&
          archives.each_with_index.all? do |archive, index|
            exact!(archive, ARCHIVE_KEYS, "archive admission")
            package = packages.fetch(index)
            archive["label"] == WORKFLOW_CREATOR_ARCHIVE_LABELS.fetch(index) &&
            archive["artifact_sha256"] == package["sha256"] && archive["artifact_size"].is_a?(Integer) &&
              archive["artifact_size"] == package["size"] &&
              archive["policy_sha256"] == WORKFLOW_CREATOR_ARCHIVE_POLICY_SHA256 &&
              archive["entry_count"].is_a?(Integer) && archive["entry_count"].between?(1, MAX_ARCHIVE_ENTRIES) &&
              archive["uncompressed_bytes"].is_a?(Integer) &&
              archive["uncompressed_bytes"].between?(1, MAX_ARCHIVE_BYTES) &&
              archive["status"] == "passed"
          end
        raise Error, "workflow-creator execution archive admission is invalid" unless archive_valid
      end

      def validate_processes!(receipt)
        commands = receipt["commands"]
        command_valid = commands.is_a?(Array) && commands.length == WORKFLOW_CREATOR_COMMANDS.length &&
          commands.each_with_index.all? do |command, index|
            exact!(command, COMMAND_KEYS, "command receipt")
            command["position"].is_a?(Integer) && command["position"] == index + 1 &&
              command["argv"] == WORKFLOW_CREATOR_COMMANDS.fetch(index) &&
              valid_process?(command, "attempt_label")
          end
        raise Error, "workflow-creator execution command receipts are invalid" unless command_valid
        outer = receipt["outer_processes"]
        outer_valid = outer.is_a?(Array) && outer.length == WORKFLOW_CREATOR_OUTER_ROLES.length &&
          outer.each_with_index.all? do |process, index|
            exact!(process, OUTER_KEYS, "outer process receipt")
            expected = WORKFLOW_CREATOR_OUTER_ROLES.fetch(index)
            process.slice("role", "prompt_sha256") == expected && process["argv_sha256"].is_a?(String) &&
              SAFE_DIGEST.match?(process["argv_sha256"]) &&
              valid_process?(process, "label")
          end
        raise Error, "workflow-creator execution outer processes are invalid" unless outer_valid
        raise Error, "workflow-creator execution outer argv identities are invalid" unless
          outer.map { |process| process["argv_sha256"] }.uniq.length == outer.length
        labels = commands.map { |command| command.fetch("attempt_label") } +
          outer.map { |process| process.fetch("label") }
        raise Error, "workflow-creator execution process labels are invalid" unless labels.uniq.length == labels.length
        labels
      end

      def valid_process?(process, label_key)
        capture = process["capture"]
        teardown = process["teardown"]
        exact!(capture, CAPTURE_KEYS, "process capture")
        exact!(capture["secret_scan"], %w[scanner status], "capture secret scan")
        exact!(teardown, PROCESS_TEARDOWN_KEYS, "process teardown")
        limit = capture["limit_bytes"]
        booleans = [ true, false ]
        byte_counts = %w[stdout_bytes stderr_bytes].all? do |field|
          capture[field].is_a?(Integer) && limit.is_a?(Integer) && capture[field].between?(0, limit)
        end
        digests = %w[stdout_sha256 stderr_sha256].all? do |field|
          capture[field].is_a?(String) && SAFE_DIGEST.match?(capture[field])
        end
        valid = process[label_key].is_a?(String) && LABEL.match?(process[label_key]) &&
          process["exit_code"].is_a?(Integer) && process["exit_code"].zero? && process["signal"].nil? &&
          process["completed"] == true && limit.is_a?(Integer) && limit.between?(1, MAX_CAPTURE_BYTES) &&
          byte_counts && digests && booleans.include?(capture["stdout_truncated"]) &&
          booleans.include?(capture["stderr_truncated"]) &&
          capture["secret_scan"] == { "status" => "passed", "scanner" => WORKFLOW_CREATOR_SCANNER } &&
          teardown["status"] == "passed" && booleans.include?(teardown["term_sent"]) &&
          booleans.include?(teardown["kill_sent"]) &&
          (!teardown["kill_sent"] || teardown["term_sent"]) && teardown["reaped"] == true &&
          teardown["descendants"] == "none" && teardown["owner_complete"] == true
        raise Error, "workflow-creator execution process receipt is invalid" unless valid
        true
      end

      def validate_aggregates!(receipt, row, labels, receipt_sha256)
        run = receipt["run"]
        exact!(run, RUN_KEYS, "execution run")
        exact!(receipt["containment"], CONTAINMENT_KEYS, "execution containment")
        exact!(receipt["teardown"], TEARDOWN_KEYS, "execution teardown")
        exact!(receipt["cleanup"], CLEANUP_KEYS, "execution cleanup")
        correlation = run["correlation_id"]
        containment = receipt["containment"]
        teardown = receipt["teardown"]
        targets = receipt["cleanup"]["targets"]
        targets_valid = targets.is_a?(Array) && targets.length == WORKFLOW_CREATOR_CLEANUP_LABELS.length &&
          targets.each_with_index.all? do |target, index|
            exact!(target, TARGET_KEYS, "cleanup target")
            target["label"] == WORKFLOW_CREATOR_CLEANUP_LABELS.fetch(index) &&
              target["path_sha256"].is_a?(String) && SAFE_DIGEST.match?(target["path_sha256"]) &&
              target["device"].is_a?(Integer) && target["device"] >= 0 &&
              target["inode"].is_a?(Integer) && target["inode"].positive? &&
              target.values_at("created_by_run", "identity_matched", "removed") == [ true, true, true ]
          end
        summary = { "status" => "passed", "receipt_sha256" => receipt_sha256 }
        valid = correlation.is_a?(String) && LABEL.match?(correlation) &&
          run["expected_labels"] == labels &&
          receipt["gateway"]["command_labels"] == labels.first(WORKFLOW_CREATOR_COMMANDS.length) &&
          containment == { "status" => "passed", "mechanism" => "supervised-process-tree",
                           "established_before_launch" => true,
                           "owner_correlation_id" => correlation,
                           "root_loss_behavior" => "fail-closed" } &&
          teardown == { "status" => "passed", "expected_labels" => labels,
                        "receipt_labels" => labels, "outer_root_reaped" => true,
                        "remaining_descendants" => 0 } &&
          teardown["remaining_descendants"].is_a?(Integer) &&
          receipt["cleanup"]["status"] == "passed" && targets_valid &&
          receipt["authored_instruction"] == row["executed_instruction"] &&
          receipt["executed_instruction"] == row["executed_instruction"] &&
          receipt["external_actions"] == row["external_actions"] &&
          receipt_sha256.is_a?(String) && SAFE_DIGEST.match?(receipt_sha256) &&
          %w[containment teardown cleanup].all? { |field| row[field] == summary }
        raise Error, "workflow-creator execution aggregates are inconsistent" unless valid
      end

      def exact!(value, keys, label)
        raise Error, "workflow-creator #{label} fields are invalid" unless value.is_a?(Hash) && value.keys.sort == keys.sort
      end
    end
  end
end
