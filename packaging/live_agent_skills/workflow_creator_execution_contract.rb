require_relative "workflow_creator_contract"
module HiveLiveAgentProof
  module WorkflowCreator
    module ExecutionContract
      KEYS = Primitives.deep_freeze(%w[
        schema schema_version candidate_sha result execution_plan classification
        installed_manifests run gateway archive_admissions commands outer_processes
        authored_instruction executed_instruction external_actions containment teardown cleanup secret_scan])
      COMMAND_KEYS = Primitives.deep_freeze(%w[position attempt_label argv exit_code signal completed capture teardown])
      OUTER_KEYS = Primitives.deep_freeze(%w[label role argv_sha256 prompt_sha256 exit_code signal completed capture teardown])
      CAPTURE_KEYS = Primitives.deep_freeze(%w[
        limit_bytes stdout_bytes stderr_bytes stdout_sha256 stderr_sha256 stdout_truncated stderr_truncated secret_scan])
      PROCESS_TEARDOWN_KEYS = Primitives.deep_freeze(%w[status term_sent kill_sent reaped descendants owner_complete])
      ARCHIVE_KEYS = Primitives.deep_freeze(%w[label artifact_sha256 artifact_size policy_sha256 entry_count uncompressed_bytes status])
      RUN_KEYS = Primitives.deep_freeze(%w[correlation_id expected_labels])
      GATEWAY_KEYS = Primitives.deep_freeze(%w[identity command_labels status])
      CONTAINMENT_KEYS = Primitives.deep_freeze(%w[status mechanism established_before_launch owner_correlation_id root_loss_behavior])
      TEARDOWN_KEYS = Primitives.deep_freeze(%w[status expected_labels receipt_labels outer_root_reaped remaining_descendants])
      CLEANUP_KEYS = Primitives.deep_freeze(%w[status targets])
      TARGET_KEYS = Primitives.deep_freeze(%w[label path_sha256 device inode created_by_run identity_matched removed])
      LABEL = /\A[a-z][a-z0-9_-]{0,127}\z/.freeze
      MAX_CAPTURE_BYTES, MAX_ARCHIVE_ENTRIES, MAX_ARCHIVE_BYTES = 1_048_576, 16_384, 1_073_741_824
      module_function
      def validate!(receipt:, row:, candidate_sha:, manifest:, installation_records:,
                    receipt_sha256:, candidate_installation:, openclaw_installation:)
        Primitives.canonical_json([ receipt, row, candidate_sha, manifest, installation_records, receipt_sha256,
                                    candidate_installation, openclaw_installation ])
        Contract::ASSERT.call(receipt.instance_of?(Hash) && receipt.keys.sort == KEYS.sort, "workflow-creator execution receipt fields are invalid")
        receipt_bytes = Primitives.canonical_json(receipt)
        bundles = installation_records + [ row.fetch("evidence_bundle").fetch(2) ]
        Contract.validate_primary!(row:, manifest:, candidate_sha:, bundle_records: bundles)
        Contract.validate_installation!(document: candidate_installation, kind: "candidate", manifest:, candidate_sha:)
        Contract.validate_installation!(document: openclaw_installation, kind: "openclaw", manifest:, candidate_sha:)
        validate_identity!(receipt, row, candidate_sha, installation_records, candidate_installation, openclaw_installation)
        labels = validate_processes!(receipt)
        validate_aggregates!(receipt, row, labels, receipt_sha256, receipt_bytes)
        Contract::ASSERT.call(Primitives.secret_findings(JSON.generate(receipt)).empty?,
                              "workflow-creator execution receipt contains secret-shaped material")
        receipt
      rescue KeyError, TypeError, NoMethodError, ArgumentError, EncodingError, JSON::GeneratorError
        raise Error, "workflow-creator execution receipt is invalid"
      end
      def validate_identity!(receipt, row, candidate_sha, records, candidate, openclaw)
        exact = ->(value, keys) { value.instance_of?(Hash) && value.keys.sort == keys.sort }
        bundle_record = lambda do |value|
          exact.call(value, Contract::BUNDLE_KEYS) && value["sha256"].instance_of?(String) && Contract::DIGEST.match?(value["sha256"]) &&
            value["size"].instance_of?(Integer) && value["size"].positive?
        end
        expected = %w[candidate-installed-manifest.json openclaw-installed-manifest.json].zip(%w[candidate_installation openclaw_installation])
        record_list = lambda do |items|
          items.instance_of?(Array) && items.length == 2 && items.each_with_index.all? do |item, index|
            bundle_record.call(item) && item.values_at("path", "kind") == expected.fetch(index)
          end
        end
        Contract::ASSERT.call(record_list.call(records) && record_list.call(receipt["installed_manifests"]) &&
                    Primitives.canonical_json(receipt["installed_manifests"]) == Primitives.canonical_json(records),
                    "workflow-creator execution installation records are invalid")
        documents = [ candidate, openclaw ].map { |document| Primitives.canonical_json(document) }
        bound = documents.each_with_index.all? do |bytes, index|
          records.fetch(index).values_at("sha256", "size") == [ Digest::SHA256.hexdigest(bytes), bytes.bytesize ]
        end
        Contract::ASSERT.call(bound, "workflow-creator execution installation bytes are invalid")
        Contract::ASSERT.call(exact.call(receipt["gateway"], GATEWAY_KEYS), "workflow-creator execution gateway fields are invalid")
        gateway = candidate.fetch("required_roles").fetch("audit_gateway")
        classification = { "outer" => Vocabulary.fetch("classification"), "nested_stage" =>
          { "execution_kind" => "deterministic_fixture", "model_loop" => "not_exercised" } }
        valid = candidate_sha.instance_of?(String) && Contract::SHA.match?(candidate_sha) &&
          receipt["schema"] == Vocabulary.fetch("execution_schema") &&
          receipt["schema_version"].instance_of?(Integer) && receipt["schema_version"] == 1 &&
          receipt["candidate_sha"] == candidate_sha && receipt["result"] == "passed" &&
          receipt["execution_plan"] == Vocabulary.fetch("execution_plan") &&
          row.slice("execution_kind", "model_loop") == Vocabulary.fetch("classification") &&
          receipt["classification"] == classification &&
          Primitives.canonical_json(receipt["gateway"]["identity"]) == Primitives.canonical_json(gateway) &&
          receipt["gateway"]["status"] == "passed" &&
          receipt["secret_scan"] == { "status" => "passed", "scanner" => Vocabulary.fetch("scanner") }
        Contract::ASSERT.call(valid, "workflow-creator execution receipt identity is invalid")
        packages = [ candidate, openclaw ].map { |item| item.fetch("required_roles").fetch("package") }
        archives = receipt["archive_admissions"]
        archive_valid = archives.instance_of?(Array) && archives.length == 2 && archives.each_with_index.all? do |archive, index|
          package = packages.fetch(index)
          exact.call(archive, ARCHIVE_KEYS) && archive["label"] == Vocabulary.fetch("archive_labels").fetch(index) &&
            archive["artifact_sha256"] == package["sha256"] && archive["artifact_size"].instance_of?(Integer) &&
            archive["artifact_size"] == package["size"] && archive["artifact_size"].positive? &&
            archive["policy_sha256"] == Vocabulary.fetch("archive_policy_sha256") &&
            archive["entry_count"].instance_of?(Integer) && archive["entry_count"].between?(1, MAX_ARCHIVE_ENTRIES) &&
            archive["uncompressed_bytes"].instance_of?(Integer) &&
            archive["uncompressed_bytes"].between?(1, MAX_ARCHIVE_BYTES) && archive["status"] == "passed"
        end
        Contract::ASSERT.call(archive_valid, "workflow-creator execution archive admission is invalid")
      end
      def validate_processes!(receipt)
        exact = ->(value, keys) { value.instance_of?(Hash) && value.keys.sort == keys.sort }
        commands = receipt["commands"]
        valid_commands = commands.instance_of?(Array) && commands.length == Vocabulary.fetch("commands").length &&
          commands.each_with_index.all? do |command, index|
            exact.call(command, COMMAND_KEYS) && command["position"].instance_of?(Integer) &&
              command["position"] == index + 1 && command["argv"] == Vocabulary.fetch("commands").fetch(index) &&
              valid_process?(command, "attempt_label")
          end
        Contract::ASSERT.call(valid_commands, "workflow-creator execution command receipts are invalid")
        outer = receipt["outer_processes"]
        valid_outer = outer.instance_of?(Array) && outer.length == Vocabulary.fetch("outer_roles").length &&
          outer.each_with_index.all? do |process, index|
            exact.call(process, OUTER_KEYS) &&
              process.slice("role", "prompt_sha256") == Vocabulary.fetch("outer_roles").fetch(index) &&
              process["argv_sha256"].instance_of?(String) && Contract::DIGEST.match?(process["argv_sha256"]) &&
              valid_process?(process, "label")
          end
        Contract::ASSERT.call(valid_outer, "workflow-creator execution outer processes are invalid")
        Contract::ASSERT.call(outer.map { |process| process["argv_sha256"] }.uniq.length == outer.length,
                    "workflow-creator execution outer argv identities are invalid")
        labels = commands.map { |command| command.fetch("attempt_label") } + outer.map { |process| process.fetch("label") }
        Contract::ASSERT.call(labels.uniq.length == labels.length, "workflow-creator execution process labels are invalid")
        labels
      end
      def valid_process?(process, label_key)
        exact = ->(value, keys) { value.instance_of?(Hash) && value.keys.sort == keys.sort }
        capture, teardown = process.values_at("capture", "teardown")
        limit = capture.instance_of?(Hash) ? capture["limit_bytes"] : nil
        boolean, empty_digest = [ true, false ], Digest::SHA256.hexdigest("")
        streams_valid = %w[stdout stderr].all? do |stream|
          bytes, digest, truncated = capture.values_at("#{stream}_bytes", "#{stream}_sha256", "#{stream}_truncated")
          bytes.instance_of?(Integer) && bytes.between?(0, limit) && digest.instance_of?(String) &&
            Contract::DIGEST.match?(digest) && boolean.include?(truncated) && (!bytes.zero? || digest == empty_digest) &&
            (!truncated || bytes == limit)
        end
        valid = exact.call(capture, CAPTURE_KEYS) && exact.call(capture["secret_scan"], %w[scanner status]) &&
          exact.call(teardown, PROCESS_TEARDOWN_KEYS) && process[label_key].instance_of?(String) &&
          LABEL.match?(process[label_key]) && process["exit_code"].instance_of?(Integer) && process["exit_code"].zero? &&
          process["signal"].nil? && process["completed"] == true && limit.instance_of?(Integer) &&
          limit.between?(1, MAX_CAPTURE_BYTES) && streams_valid &&
          capture["secret_scan"] == { "status" => "passed", "scanner" => Vocabulary.fetch("scanner") } &&
          teardown["status"] == "passed" && boolean.include?(teardown["term_sent"]) &&
          boolean.include?(teardown["kill_sent"]) && (!teardown["kill_sent"] || teardown["term_sent"]) &&
          teardown["reaped"] == true && teardown["descendants"] == "none" && teardown["owner_complete"] == true
        Contract::ASSERT.call(valid, "workflow-creator execution process receipt is invalid")
        true
      end
      def validate_aggregates!(receipt, row, labels, receipt_sha256, receipt_bytes)
        exact = ->(value, keys) { value.instance_of?(Hash) && value.keys.sort == keys.sort }
        run, containment, teardown, cleanup = receipt.values_at("run", "containment", "teardown", "cleanup")
        Contract::ASSERT.call(exact.call(run, RUN_KEYS) && exact.call(containment, CONTAINMENT_KEYS) &&
                    exact.call(teardown, TEARDOWN_KEYS) && exact.call(cleanup, CLEANUP_KEYS),
                    "workflow-creator execution aggregate fields are invalid")
        correlation, targets = run["correlation_id"], cleanup["targets"]
        target_valid = targets.instance_of?(Array) && targets.length == Vocabulary.fetch("cleanup_labels").length &&
          targets.each_with_index.all? do |target, index|
            exact.call(target, TARGET_KEYS) && target["label"] == Vocabulary.fetch("cleanup_labels").fetch(index) &&
              target["path_sha256"].instance_of?(String) && Contract::DIGEST.match?(target["path_sha256"]) &&
              target["device"].instance_of?(Integer) && target["device"] >= 0 && target["inode"].instance_of?(Integer) &&
              target["inode"].positive? && target.values_at("created_by_run", "identity_matched", "removed") == [ true, true, true ]
          end
        instruction = ->(value) do
          exact.call(value, Contract::FILE_KEYS) && Primitives.safe_relative_path?(value["path"]) && value["sha256"].instance_of?(String) &&
            Contract::DIGEST.match?(value["sha256"]) && value["size"].instance_of?(Integer) && value["size"].positive?
        end
        receipt_record = row.fetch("evidence_bundle").fetch(2)
        receipt_identity = [ Digest::SHA256.hexdigest(receipt_bytes), receipt_bytes.bytesize ]
        summary = { "status" => "passed", "receipt_sha256" => receipt_sha256 }
        valid = correlation.instance_of?(String) && LABEL.match?(correlation) && run["expected_labels"] == labels &&
          receipt["gateway"]["command_labels"] == labels.first(Vocabulary.fetch("commands").length) &&
          containment == { "status" => "passed", "mechanism" => "supervised-process-tree", "established_before_launch" => true,
                           "owner_correlation_id" => correlation,
                           "root_loss_behavior" => "fail-closed" } &&
          teardown == { "status" => "passed", "expected_labels" => labels, "receipt_labels" => labels,
                        "outer_root_reaped" => true, "remaining_descendants" => 0 } &&
          cleanup["status"] == "passed" && target_valid &&
          instruction.call(row["executed_instruction"]) && instruction.call(receipt["authored_instruction"]) &&
          instruction.call(receipt["executed_instruction"]) &&
          receipt["authored_instruction"] == row["executed_instruction"] &&
          receipt["executed_instruction"] == row["executed_instruction"] &&
          receipt["external_actions"] == [] && row["external_actions"] == [] &&
          receipt_record.values_at("sha256", "size") == receipt_identity && receipt_sha256 == receipt_identity.first &&
          %w[containment teardown cleanup].all? { |field| row[field] == summary }
        Contract::ASSERT.call(valid, "workflow-creator execution aggregates are inconsistent")
      end
    end
  end
end
