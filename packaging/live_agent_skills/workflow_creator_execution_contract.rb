# frozen_string_literal: true

module HiveLiveAgentProof::WorkflowCreator
    module ExecutionContract
      KEYS = %w[schema schema_version candidate_sha result execution_plan classification installed_manifests run gateway
                task_slug_binding archive_admissions commands outer_processes authored_instruction executed_instruction
                external_actions
                containment teardown cleanup secret_scan].freeze
      COMMAND_KEYS = %w[position attempt_label argv exit_code signal completed capture teardown].freeze
      OUTER_KEYS = %w[label role argv_sha256 prompt_sha256 exit_code signal completed capture teardown].freeze
      CAPTURE_KEYS = %w[limit_bytes stdout_bytes stderr_bytes stdout_sha256 stderr_sha256 stdout_truncated
                        stderr_truncated secret_scan].freeze
      PROCESS_TEARDOWN_KEYS = %w[status term_sent kill_sent reaped descendants owner_complete].freeze
      ARCHIVE_KEYS = %w[label artifact_sha256 artifact_size policy_sha256 entry_count uncompressed_bytes status].freeze
      RUN_KEYS, GATEWAY_KEYS = %w[correlation_id expected_labels].freeze, %w[identity command_labels status].freeze
      BINDING_KEYS = %w[source_position source_result_field target_position target_argument template value].freeze
      CONTAINMENT_KEYS = %w[status mechanism established_before_launch owner_correlation_id root_loss_behavior].freeze
      TEARDOWN_KEYS = %w[status expected_labels receipt_labels outer_root_reaped remaining_descendants].freeze
      CLEANUP_KEYS, LABEL = %w[status targets].freeze, /\A[a-z][a-z0-9_-]{0,127}\z/.freeze
      TARGET_KEYS = %w[label path_sha256 device inode created_by_run identity_matched removed].freeze
      module_function
      def validate!(receipt_snapshot, row_snapshot, candidate_snapshot, manifest_snapshot, records_snapshot,
                    receipt_sha_snapshot, candidate_installation_snapshot, openclaw_installation_snapshot)
        receipt, row = receipt_snapshot.value, row_snapshot.value
        candidate_sha, records = candidate_snapshot.value, records_snapshot.value
        Contract.exact!(receipt, KEYS, "workflow-creator execution receipt fields are invalid")
        bundles = Values.capture(records + [ row.fetch("evidence_bundle").fetch(2) ])
        Contract.validate_primary!(row_snapshot, manifest_snapshot, candidate_snapshot, bundles)
        Contract.validate_installation!(candidate_installation_snapshot, Values.capture("candidate"),
                                        manifest_snapshot, candidate_snapshot)
        Contract.validate_installation!(openclaw_installation_snapshot, Values.capture("openclaw"),
                                        manifest_snapshot, candidate_snapshot)
        identity!(receipt, row, candidate_sha, records, candidate_installation_snapshot, openclaw_installation_snapshot)
        labels, correlation = processes!(receipt, row)
        aggregates!(receipt, row, labels, correlation, receipt_sha_snapshot.value, receipt_snapshot.canonical_bytes)
        receipt_snapshot
      rescue ArgumentError, IndexError, KeyError, NoMethodError, TypeError, Values::Error, TextSafety::Error
        raise Error, "workflow-creator execution receipt is invalid"
      end
      def identity!(receipt, row, candidate_sha, records, candidate_snapshot, openclaw_snapshot)
        message = "workflow-creator execution identity is inconsistent"
        installed = receipt.fetch("installed_manifests")
        installation_records!(records, installed, candidate_snapshot, openclaw_snapshot)
        Contract.assert!(Values.capture(installed).canonical_bytes == Values.capture(records).canonical_bytes, message)
        candidate, openclaw = candidate_snapshot.value, openclaw_snapshot.value
        execution_identity!(receipt, row, candidate_sha, candidate)
        instruction = row.fetch("executed_instruction")
        instructions = receipt.values_at("authored_instruction", "executed_instruction")
        Contract.assert!(instructions == [ instruction ] * 2, message)
        Contract.assert!(receipt.fetch("external_actions") == [], "workflow-creator external actions are invalid")
        archives = receipt.fetch("archive_admissions")
        Contract.assert!([ archives.class, archives.length ] == [ Array, 2 ], message)
        archives!(archives, candidate, openclaw)
      end
      def installation_records!(records, installed, candidate_snapshot, openclaw_snapshot)
        message = "workflow-creator execution installation records are invalid"
        Contract.assert!([ records.class, records.length ] == [ Array, 2 ], message)
        Contract.assert!([ installed.class, installed.length ] == [ Array, 2 ], message)
        paths = Vocabulary.fetch("bundle_files").slice(1, 2)
        kinds = %w[candidate_installation openclaw_installation]
        records.each_with_index do |record, index|
          Contract.record!(record, Contract::BUNDLE_KEYS, message, path: true, positive: true,
                           binding: [ paths.fetch(index), kinds.fetch(index) ])
        end
        [ candidate_snapshot, openclaw_snapshot ].each_with_index do |snapshot, index|
          expected = [ Digest::SHA256.hexdigest(snapshot.canonical_bytes), snapshot.canonical_bytes.bytesize ]
          Contract.assert!(records.fetch(index).values_at("sha256", "size") == expected, message)
        end
      end
      def execution_identity!(receipt, row, candidate_sha, candidate)
        schema, plan, classification, scanner = Vocabulary.values_at(
          "execution_schema", "execution_plan", "classification", "scanner")
        nested = { "execution_kind" => "deterministic_fixture", "model_loop" => "not_exercised" }
        expected = {
          "schema" => schema, "schema_version" => 1, "candidate_sha" => candidate_sha, "result" => "passed",
          "execution_plan" => plan, "classification" => { "outer" => classification, "nested_stage" => nested },
          "secret_scan" => { "status" => "passed", "scanner" => scanner }
        }
        Contract.assert!(receipt.slice(*expected.keys) == expected, "workflow-creator execution identity is invalid")
        Contract.assert!(receipt.fetch("schema_version").instance_of?(Integer),
                         "workflow-creator execution identity is invalid")
        Contract.assert!(Contract::SHA.match?(candidate_sha), "workflow-creator execution identity is invalid")
        Contract.assert!(row.values_at("execution_kind", "model_loop") == classification.values,
                         "workflow-creator execution identity is invalid")
        gateway = receipt.fetch("gateway")
        Contract.exact!(gateway, GATEWAY_KEYS, "workflow-creator execution gateway fields are invalid")
        Contract.assert!(gateway.fetch("identity") == candidate.fetch("required_roles").fetch("audit_gateway"),
                         "workflow-creator execution gateway identity is invalid")
        Contract.assert!(gateway.fetch("status") == "passed", "workflow-creator execution gateway is not passing")
      end
      def archives!(archives, candidate, openclaw)
        message = "workflow-creator execution archive admission is invalid"
        packages = [ candidate, openclaw ].map { |document| document.fetch("required_roles").fetch("package") }
        archives.zip(packages, Vocabulary.fetch("archive_labels")).each do |archive, package, expected_label|
          Contract.exact!(archive, ARCHIVE_KEYS, message)
          label, digest, size, policy, entries, bytes, status = archive.values_at(*ARCHIVE_KEYS)
          expected = [ expected_label, package.fetch("sha256"),
                       package.fetch("size"), Vocabulary.fetch("archive_policy_sha256"), "passed" ]
          Contract.assert!([ label, digest, size, policy, status ] == expected, message)
          Contract.assert!([ size, entries, bytes ].all? { |value| value.instance_of?(Integer) }, message)
          Contract.assert!(size.positive? && entries.between?(1, 16_384) && bytes.between?(1, 1_073_741_824), message)
        end
      end
      def processes!(receipt, row)
        binding = receipt.fetch("task_slug_binding")
        commands = commands!(receipt.fetch("commands"), binding)
        Contract.assert!(row.dig("task", "slug") == binding.fetch("value"),
                         "workflow-creator task slug binding is invalid")
        outer = outer_processes!(receipt.fetch("outer_processes"))
        labels = commands + outer
        Contract.assert!(labels.uniq.length == labels.length, "workflow-creator execution process labels are invalid")
        run = receipt.fetch("run")
        Contract.exact!(run, RUN_KEYS, "workflow-creator execution run fields are invalid")
        correlation = run.fetch("correlation_id")
        Contract.assert!(LABEL.match?(correlation), "workflow-creator execution run identity is invalid")
        Contract.assert!(run.fetch("expected_labels") == labels, "workflow-creator execution run labels are invalid")
        Contract.assert!(receipt.fetch("gateway").fetch("command_labels") == commands,
                         "workflow-creator execution gateway labels are invalid")
        [ labels, correlation ]
      end
      def commands!(commands, binding)
        message = "workflow-creator command receipts are invalid"
        Contract.exact!(binding, BINDING_KEYS, message)
        Contract.assert!(binding.except("value") == Vocabulary.fetch("task_slug_binding"), message)
        expected = HiveLiveAgentProof::WorkflowCreator.commands_for(task_slug: binding.fetch("value")).value
        labels = Vocabulary.fetch("command_labels")
        Contract.assert!(commands.instance_of?(Array), message)
        Contract.assert!(commands.length == expected.length, message)
        commands.each_with_index.map do |command, index|
          command!(command, index, expected.fetch(index), labels.fetch(index), message)
        end
      end
      def command!(command, index, expected, label, message)
        Contract.exact!(command, COMMAND_KEYS, message)
        position, argv = command.values_at("position", "argv")
        Contract.assert!([ position.class, position, argv, command.fetch("attempt_label") ] ==
                         [ Integer, index + 1, expected, label ], message)
        process!(command, "attempt_label")
        command.fetch("attempt_label")
      end
      def outer_processes!(outer)
        expected = Vocabulary.fetch("outer_roles")
        message = "workflow-creator outer processes are invalid"
        Contract.assert!(outer.instance_of?(Array), message)
        Contract.assert!(outer.length == expected.length, message)
        outer.each_with_index.map do |process, index|
          Contract.exact!(process, OUTER_KEYS, message)
          Contract.assert!(process.values_at("role", "prompt_sha256") == expected.fetch(index).values, message)
          Contract.assert!(Contract::DIGEST.match?(process.fetch("argv_sha256")), message)
          process!(process, "label")
          process.fetch("label")
        end
      end
      def process!(process, label_key)
        Contract.assert!(LABEL.match?(process.fetch(label_key)), "workflow-creator process label is invalid")
        exit_code, signal, completed = process.values_at("exit_code", "signal", "completed")
        Contract.assert!([ exit_code.class, exit_code, signal, completed ] == [ Integer, 0, nil, true ],
                         "workflow-creator process result is invalid")
        capture!(process.fetch("capture"))
        teardown!(process.fetch("teardown"))
      end
      def capture!(capture)
        message = "workflow-creator execution capture is invalid"
        Contract.exact!(capture, CAPTURE_KEYS, message)
        limit = capture.fetch("limit_bytes")
        Contract.assert!(limit.instance_of?(Integer), message)
        Contract.assert!(limit.between?(1, 1_048_576), message)
        empty_digest = Digest::SHA256.hexdigest("")
        %w[stdout stderr].each do |stream|
          bytes, digest, truncated = capture.values_at("#{stream}_bytes", "#{stream}_sha256", "#{stream}_truncated")
          checks = [ bytes.instance_of?(Integer), bytes.between?(0, limit), Contract::DIGEST.match?(digest),
                     [ true, false ].include?(truncated), bytes.zero? == (digest == empty_digest),
                     !truncated || bytes == limit ]
          Contract.assert!(checks.all?, message)
        end
        scan = capture.fetch("secret_scan")
        Contract.assert!(scan == { "status" => "passed", "scanner" => Vocabulary.fetch("scanner") }, message)
      end
      def teardown!(teardown)
        message = "workflow-creator execution teardown is invalid"
        Contract.exact!(teardown, PROCESS_TEARDOWN_KEYS, message)
        status, term, kill, reaped, descendants, owner = teardown.values_at(*PROCESS_TEARDOWN_KEYS)
        Contract.assert!([ status, reaped, descendants, owner ] == [ "passed", true, "none", true ], message)
        Contract.assert!([ term, kill ].all? { |value| [ true, false ].include?(value) }, message)
        Contract.assert!(!kill || term, message)
      end
      def aggregates!(receipt, row, labels, correlation, receipt_sha256, receipt_bytes)
        containment, teardown, cleanup = receipt.values_at("containment", "teardown", "cleanup")
        invalid = "workflow-creator execution aggregates are inconsistent"
        cleanup_targets!(cleanup.fetch("targets"))
        expected_containment = {
          "status" => "passed", "mechanism" => "supervised-process-tree", "established_before_launch" => true,
          "owner_correlation_id" => correlation, "root_loss_behavior" => "fail-closed"
        }
        expected_teardown = { "status" => "passed", "expected_labels" => labels, "receipt_labels" => labels,
                              "outer_root_reaped" => true, "remaining_descendants" => 0 }
        Contract.exact!(containment, CONTAINMENT_KEYS, invalid, expected: expected_containment)
        Contract.exact!(teardown, TEARDOWN_KEYS, invalid, expected: expected_teardown)
        Contract.exact!(cleanup, CLEANUP_KEYS, invalid, expected: { "status" => "passed" })
        actual_identity = row.fetch("evidence_bundle").fetch(2).values_at("sha256", "size")
        expected_identity = [ receipt_sha256, receipt_bytes.bytesize ]
        summary = { "status" => "passed", "receipt_sha256" => receipt_sha256 }
        Contract.assert!(teardown.fetch("remaining_descendants").instance_of?(Integer), invalid)
        Contract.assert!(actual_identity == expected_identity, invalid)
        Contract.assert!(receipt_sha256 == Digest::SHA256.hexdigest(receipt_bytes), invalid)
        Contract.assert!(%w[containment teardown cleanup].all? { |field| row.fetch(field) == summary }, invalid)
      end
      def cleanup_targets!(targets)
        labels = Vocabulary.fetch("cleanup_labels")
        message = "workflow-creator execution cleanup targets are invalid"
        Contract.assert!(targets.instance_of?(Array), message)
        Contract.assert!(targets.length == labels.length, message)
        targets.each_with_index do |target, index|
          Contract.exact!(target, TARGET_KEYS, message)
          label, path, device, inode, created, matched, removed = target.values_at(*TARGET_KEYS)
          Contract.assert!([ label, created, matched, removed ] == [ labels.fetch(index), true, true, true ], message)
          Contract.assert!(Contract::DIGEST.match?(path), message)
          Contract.assert!([ device.class, inode.class ] == [ Integer, Integer ], message)
          Contract.assert!(device >= 0, message)
          Contract.assert!(inode.positive?, message)
        end
      end
    end
end
