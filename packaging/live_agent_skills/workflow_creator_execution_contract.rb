require_relative "proof_primitives"
require_relative "workflow_creator_vocabulary"

module HiveLiveAgentProof
  # Pure schema and cross-binding validation for evidence that U14 and U15
  # produce later. This class owns no process, provider, archive, or cleanup
  # behavior; it only prevents those units from redefining the retained proof.
  class WorkflowCreatorExecutionContract
    RECEIPT_KEYS = %w[
      schema schema_version candidate_sha result execution_plan classification run
      installed_manifests gateway archive_admissions commands outer_processes
      executed_instruction external_actions containment teardown cleanup secret_scan
    ].freeze
    CLASSIFICATION_KEYS = %w[nested_stage outer].freeze
    CLASSIFICATION_VALUE_KEYS = %w[execution_kind model_loop].freeze
    RUN_KEYS = %w[correlation_id expected_labels].freeze
    ARCHIVE_KEYS = %w[
      label artifact_sha256 artifact_size policy_sha256 entry_count
      uncompressed_bytes status
    ].freeze
    COMMAND_KEYS = %w[
      position attempt_label argv exit_code signal completed capture teardown
    ].freeze
    OUTER_PROCESS_KEYS = %w[
      label role argv_sha256 prompt_sha256 exit_code signal completed capture
      teardown
    ].freeze
    CAPTURE_KEYS = %w[
      limit_bytes stdout_bytes stderr_bytes stdout_sha256 stderr_sha256
      stdout_truncated stderr_truncated secret_scan
    ].freeze
    PROCESS_TEARDOWN_KEYS = %w[
      status term_sent kill_sent reaped descendants owner_complete
    ].freeze
    CONTAINMENT_KEYS = %w[
      status mechanism established_before_launch owner_correlation_id
      root_loss_behavior
    ].freeze
    TEARDOWN_KEYS = %w[
      status expected_labels receipt_labels outer_root_reaped
      remaining_descendants
    ].freeze
    CLEANUP_KEYS = %w[status targets].freeze
    CLEANUP_TARGET_KEYS = %w[
      label path_sha256 device inode created_by_run identity_matched removed
    ].freeze
    SECRET_SCAN_KEYS = %w[scanner status].freeze
    PROVIDER_KEYS = %w[credential_environment model name].freeze
    TRANSPORT_KEYS = %w[ca endpoint_origin proxy].freeze
    TRANSPORT_VALUE_KEYS = %w[mode sha256].freeze
    CREDENTIAL_BOUNDARY_KEYS = %w[candidate gateway openclaw tools].freeze
    OPENCLAW_PROVENANCE_KEYS = %w[
      approval integrity_tree_sha256 lifecycle_policy_sha256 registry_origin
    ].freeze
    APPROVAL_KEYS = %w[candidate_sha lock_sha256 policy_sha256].freeze
    SUMMARY_KEYS = %w[receipt_sha256 status].freeze
    DIGEST = /\A[0-9a-f]{64}\z/.freeze
    LABEL = /\A[a-z][a-z0-9_-]{0,127}\z/.freeze
    ENVIRONMENT_NAME = /\A[A-Z][A-Z0-9_]{0,127}\z/.freeze
    HTTPS_ORIGIN = %r{\Ahttps://[A-Za-z0-9.-]+(?::[0-9]{1,5})?\z}.freeze
    MAX_CAPTURE_BYTES = 1_048_576
    MAX_ARCHIVE_ENTRIES = 16_384
    MAX_ARCHIVE_BYTES = 1_073_741_824
    OUTER_CLASSIFICATION = {
      "execution_kind" => "authenticated_openclaw",
      "model_loop" => "executed"
    }.freeze
    NESTED_CLASSIFICATION = {
      "execution_kind" => "deterministic_fixture",
      "model_loop" => "not_exercised"
    }.freeze
    ARCHIVE_LABELS = %w[candidate_package openclaw_package].freeze

    class << self
      def validate!(receipt:, row:, candidate_sha:, candidate_installation:,
                    openclaw_installation:)
        exact_hash!(receipt, RECEIPT_KEYS, "execution receipt")
        validate_identity!(receipt, row, candidate_sha)
        validate_installations!(
          receipt,
          row,
          candidate_installation,
          openclaw_installation
        )
        labels = validate_process_receipts!(receipt)
        validate_aggregates!(receipt, row, labels)
        validate_provider_boundary!(row)
        validate_openclaw_provenance!(
          openclaw_installation.fetch("identity"), candidate_sha
        )
        reject_secrets!(receipt, "execution receipt")
        receipt
      end

      private

      def validate_identity!(receipt, row, candidate_sha)
        exact_hash!(
          receipt["classification"],
          CLASSIFICATION_KEYS,
          "execution classification"
        )
        receipt.fetch("classification").each_value do |classification|
          exact_hash!(
            classification,
            CLASSIFICATION_VALUE_KEYS,
            "execution classification value"
          )
        end
        valid =
          receipt["schema"] == WORKFLOW_CREATOR_EXECUTION_RECEIPT_SCHEMA &&
          receipt["schema_version"] == SCHEMA_VERSION &&
          receipt["candidate_sha"] == candidate_sha &&
          receipt["result"] == "passed" &&
          receipt["execution_plan"] == WORKFLOW_CREATOR_EXECUTION_PLAN &&
          receipt.dig("classification", "outer") == OUTER_CLASSIFICATION &&
          receipt.dig("classification", "outer") == {
            "execution_kind" => row["execution_kind"],
            "model_loop" => row["model_loop"]
          } &&
          receipt.dig("classification", "nested_stage") ==
            NESTED_CLASSIFICATION
        fail_contract!("execution receipt classification is invalid") unless valid
      end

      def validate_installations!(receipt, row, candidate, openclaw)
        unless receipt["installed_manifests"] == row["evidence_bundle"].first(2)
          fail_contract!("execution receipt installed manifests are inconsistent")
        end

        gateway = candidate.fetch("required_members").fetch("audit_gateway")
        unless receipt["gateway"] == gateway
          fail_contract!("execution receipt gateway identity is inconsistent")
        end

        archives = receipt["archive_admissions"]
        unless archives.is_a?(Array) && archives.length == ARCHIVE_LABELS.length
          fail_contract!("execution receipt archive admissions are invalid")
        end
        expected_packages = [
          candidate.fetch("required_members").fetch("package"),
          openclaw.fetch("required_members").fetch("package")
        ]
        archives.each_with_index do |archive, index|
          exact_hash!(archive, ARCHIVE_KEYS, "archive admission")
          package = expected_packages.fetch(index)
          valid =
            archive["label"] == ARCHIVE_LABELS.fetch(index) &&
            archive["artifact_sha256"] == package["sha256"] &&
            archive["artifact_size"] == package["size"] &&
            digest?(archive["policy_sha256"]) &&
            archive["entry_count"].is_a?(Integer) &&
            archive["entry_count"].between?(1, MAX_ARCHIVE_ENTRIES) &&
            archive["uncompressed_bytes"].is_a?(Integer) &&
            archive["uncompressed_bytes"].between?(1, MAX_ARCHIVE_BYTES) &&
            archive["status"] == "passed"
          fail_contract!("execution receipt archive admission is invalid") unless valid
        end
      end

      def validate_process_receipts!(receipt)
        commands = receipt["commands"]
        unless commands.is_a?(Array) &&
               commands.length == WORKFLOW_CREATOR_COMMANDS.length
          fail_contract!("execution receipt command receipts are invalid")
        end
        command_labels = commands.each_with_index.map do |command, index|
          exact_hash!(command, COMMAND_KEYS, "command receipt")
          validate_completed_process!(command, label_key: "attempt_label")
          unless command["position"] == index + 1 &&
                 command["argv"] == WORKFLOW_CREATOR_COMMANDS.fetch(index)
            fail_contract!("execution receipt command order is invalid")
          end
          command.fetch("attempt_label")
        end

        outer = receipt["outer_processes"]
        unless outer.is_a?(Array) &&
               outer.length == WORKFLOW_CREATOR_OUTER_PROCESS_ROLES.length
          fail_contract!("execution receipt outer processes are invalid")
        end
        outer_argv_sha256 = []
        outer_labels = outer.each_with_index.map do |process, index|
          exact_hash!(process, OUTER_PROCESS_KEYS, "outer process receipt")
          validate_completed_process!(process, label_key: "label")
          unless process["role"] ==
                 WORKFLOW_CREATOR_OUTER_PROCESS_ROLES.fetch(index) &&
                 digest?(process["argv_sha256"]) &&
                 process["prompt_sha256"] ==
                   WORKFLOW_CREATOR_OUTER_PROMPT_SHA256.fetch(index)
            fail_contract!("execution receipt outer process identity is invalid")
          end
          outer_argv_sha256 << process.fetch("argv_sha256")
          process.fetch("label")
        end
        unless outer_argv_sha256.uniq.length == outer_argv_sha256.length
          fail_contract!("execution receipt outer process identity is invalid")
        end
        labels = command_labels + outer_labels
        unless labels.uniq.length == labels.length
          fail_contract!("execution receipt process labels are invalid")
        end
        labels
      end

      def validate_completed_process!(process, label_key:)
        validate_capture!(process["capture"])
        validate_process_teardown!(process["teardown"])
        valid =
          label?(process[label_key]) &&
          process["exit_code"] == 0 &&
          process["signal"].nil? &&
          process["completed"] == true
        fail_contract!("execution receipt process did not complete") unless valid
      end

      def validate_capture!(capture)
        exact_hash!(capture, CAPTURE_KEYS, "process capture")
        exact_hash!(capture["secret_scan"], SECRET_SCAN_KEYS, "capture secret scan")
        boolean = [ true, false ]
        limit = capture["limit_bytes"]
        valid =
          limit.is_a?(Integer) && limit.between?(1, MAX_CAPTURE_BYTES) &&
          %w[stdout_bytes stderr_bytes].all? do |field|
            capture[field].is_a?(Integer) && capture[field].between?(0, limit)
          end &&
          digest?(capture["stdout_sha256"]) &&
          digest?(capture["stderr_sha256"]) &&
          boolean.include?(capture["stdout_truncated"]) &&
          boolean.include?(capture["stderr_truncated"]) &&
          capture["secret_scan"] == {
            "status" => "passed",
            "scanner" => WORKFLOW_CREATOR_SCANNER
          }
        fail_contract!("execution receipt process capture is invalid") unless valid
      end

      def validate_process_teardown!(teardown)
        exact_hash!(teardown, PROCESS_TEARDOWN_KEYS, "process teardown")
        boolean = [ true, false ]
        valid =
          teardown["status"] == "passed" &&
          boolean.include?(teardown["term_sent"]) &&
          boolean.include?(teardown["kill_sent"]) &&
          teardown["reaped"] == true &&
          teardown["descendants"] == "none" &&
          teardown["owner_complete"] == true
        fail_contract!("execution receipt process teardown is invalid") unless valid
      end

      def validate_aggregates!(receipt, row, labels)
        run = receipt["run"]
        exact_hash!(run, RUN_KEYS, "execution run")
        unless label?(run["correlation_id"]) && run["expected_labels"] == labels
          fail_contract!("execution receipt run identity is invalid")
        end
        validate_containment!(receipt["containment"], run["correlation_id"])
        validate_teardown!(receipt["teardown"], labels)
        validate_cleanup!(receipt["cleanup"])
        exact_hash!(receipt["secret_scan"], SECRET_SCAN_KEYS, "receipt secret scan")
        unless receipt["secret_scan"] == {
          "status" => "passed", "scanner" => WORKFLOW_CREATOR_SCANNER
        }
          fail_contract!("execution receipt secret scan is invalid")
        end

        unless receipt["executed_instruction"] == row["executed_instruction"] &&
               receipt["external_actions"] == row["external_actions"]
          fail_contract!("execution receipt result bindings are inconsistent")
        end
        receipt_record = row.fetch("evidence_bundle").fetch(2)
        %w[containment teardown cleanup].each do |field|
          expected = {
            "status" => receipt.fetch(field).fetch("status"),
            "receipt_sha256" => receipt_record.fetch("sha256")
          }
          unless row[field] == expected
            fail_contract!("execution receipt #{field} summary is inconsistent")
          end
        end
      end

      def validate_containment!(containment, correlation_id)
        exact_hash!(containment, CONTAINMENT_KEYS, "execution containment")
        valid =
          containment["status"] == "passed" &&
          WORKFLOW_CREATOR_CONTAINMENT_MECHANISMS.include?(
            containment["mechanism"]
          ) &&
          containment["established_before_launch"] == true &&
          containment["owner_correlation_id"] == correlation_id &&
          WORKFLOW_CREATOR_ROOT_LOSS_BEHAVIORS.include?(
            containment["root_loss_behavior"]
          )
        fail_contract!("execution receipt containment is invalid") unless valid
      end

      def validate_teardown!(teardown, labels)
        exact_hash!(teardown, TEARDOWN_KEYS, "execution teardown")
        valid =
          teardown["status"] == "passed" &&
          teardown["expected_labels"] == labels &&
          teardown["receipt_labels"] == labels &&
          teardown["outer_root_reaped"] == true &&
          teardown["remaining_descendants"] == 0
        fail_contract!("execution receipt teardown is invalid") unless valid
      end

      def validate_cleanup!(cleanup)
        exact_hash!(cleanup, CLEANUP_KEYS, "execution cleanup")
        targets = cleanup["targets"]
        unless cleanup["status"] == "passed" && targets.is_a?(Array) &&
               targets.length == WORKFLOW_CREATOR_CLEANUP_TARGET_LABELS.length
          fail_contract!("execution receipt cleanup is invalid")
        end
        labels = targets.map do |target|
          exact_hash!(target, CLEANUP_TARGET_KEYS, "cleanup target")
          valid =
            label?(target["label"]) && digest?(target["path_sha256"]) &&
            target["device"].is_a?(Integer) && target["device"] >= 0 &&
            target["inode"].is_a?(Integer) && target["inode"].positive? &&
            target["created_by_run"] == true &&
            target["identity_matched"] == true &&
            target["removed"] == true
          fail_contract!("execution receipt cleanup target is invalid") unless valid
          target.fetch("label")
        end
        unless labels == WORKFLOW_CREATOR_CLEANUP_TARGET_LABELS
          fail_contract!("execution receipt cleanup labels are invalid")
        end
      end

      def validate_provider_boundary!(row)
        provider = row["provider"]
        transport = row["transport"]
        boundary = row["credential_boundary"]
        exact_hash!(provider, PROVIDER_KEYS, "provider provenance")
        exact_hash!(transport, TRANSPORT_KEYS, "provider transport")
        exact_hash!(boundary, CREDENTIAL_BOUNDARY_KEYS, "credential boundary")
        %w[proxy ca].each do |field|
          exact_hash!(transport[field], TRANSPORT_VALUE_KEYS, "#{field} transport")
        end
        credential = provider["credential_environment"]
        valid =
          label?(provider["name"]) &&
          provider["model"].is_a?(String) &&
          provider["model"].bytesize.between?(1, 256) &&
          provider["model"].start_with?("#{provider['name']}/") &&
          ENVIRONMENT_NAME.match?(credential.to_s) &&
          HTTPS_ORIGIN.match?(transport["endpoint_origin"].to_s) &&
          valid_transport_value?(transport["proxy"], %w[none pinned]) &&
          valid_transport_value?(transport["ca"], %w[system pinned]) &&
          boundary["openclaw"] == [ credential ] &&
          %w[tools gateway candidate].all? { |field| boundary[field] == [] }
        fail_contract!("provider credential or transport boundary is invalid") unless valid
        reject_secrets!(row.values_at("provider", "transport", "credential_boundary"),
                        "provider boundary")
      end

      def validate_openclaw_provenance!(identity, candidate_sha)
        provenance = identity["provenance"]
        exact_hash!(provenance, OPENCLAW_PROVENANCE_KEYS, "OpenClaw provenance")
        approval = provenance["approval"]
        exact_hash!(approval, APPROVAL_KEYS, "OpenClaw approval")
        valid =
          HTTPS_ORIGIN.match?(provenance["registry_origin"].to_s) &&
          digest?(provenance["integrity_tree_sha256"]) &&
          digest?(provenance["lifecycle_policy_sha256"]) &&
          approval["candidate_sha"] == candidate_sha &&
          approval["lock_sha256"] == identity["lock_sha256"] &&
          approval["policy_sha256"] == provenance["lifecycle_policy_sha256"]
        fail_contract!("OpenClaw dependency provenance is invalid") unless valid
      end

      def valid_transport_value?(value, modes)
        modes.include?(value["mode"]) &&
          if value["mode"] == "pinned"
            digest?(value["sha256"])
          else
            value["sha256"].nil?
          end
      end

      def exact_hash!(value, keys, label)
        unless value.is_a?(Hash) && value.keys.sort == keys.sort
          fail_contract!("#{label} fields are invalid")
        end
      end

      def digest?(value)
        DIGEST.match?(value.to_s)
      end

      def label?(value)
        LABEL.match?(value.to_s)
      end

      def reject_secrets!(value, label)
        findings = HiveLiveAgentProof.secret_findings(JSON.generate(value))
        fail_contract!("#{label} contains secret-shaped material") unless findings.empty?
      end

      def fail_contract!(message)
        raise Error, "workflow-creator #{message}"
      end
    end
  end
end
