# frozen_string_literal: true

module HiveLiveAgentProof::WorkflowCreator
    module Contract
      PRIMARY_KEYS = %w[schema schema_version platform candidate_sha result prompt_sha256 task_prompt_sha256 skill
                        native_activation hive_commands created_files validation creation_only_task_count task_count
                        task external_actions secret_scan execution_kind model_loop executed_instruction
                        evidence_bundle containment teardown
                        cleanup].freeze
      FAILURE = %w[schema schema_version platform candidate_sha result phase reason detail execution_kind model_loop
                    secret_scan].freeze
      MANIFEST = %w[canonical_digest candidate_sha files hive_version schema schema_version skill_version].freeze
      INSTALLATION_KEYS = %w[schema schema_version candidate_sha kind version closure_sha256 required_roles inventory
                             total_size secret_scan].freeze
      FILE_KEYS, ARTIFACT_KEYS = %w[path sha256 size].freeze, %w[sha256 size].freeze
      BUNDLE_KEYS, SUMMARY_KEYS = %w[kind path sha256 size].freeze, %w[receipt_sha256 status].freeze
      SHA = /\A[0-9a-f]{40}\z/.freeze
      DIGEST = /\A[0-9a-f]{64}\z/.freeze
      FAILURE_PART = /\A[a-z][a-z0-9_]{0,63}\z/.freeze
      CLASSIFICATIONS = Values.capture([ %w[unavailable not_started], %w[deterministic_fixture not_exercised],
                                         %w[authenticated_openclaw executed] ]).value
      OMITTED_DETAIL = "[detail omitted: unsafe or oversized]".freeze
      DETAIL_LIMIT, MAX_INVENTORY_ENTRIES = 1_000, 512
      MAX_MEMBER_BYTES, MAX_TOTAL_BYTES = 268_435_456, 1_073_741_824
      module_function
      def failure(candidate_sha:, phase:, reason:, detail: nil, execution_kind: "unavailable",
                  model_loop: "not_started", exact_secrets: [])
        base = Values.capture(
          "candidate_sha" => candidate_sha, "phase" => phase, "reason" => reason,
          "execution_kind" => execution_kind, "model_loop" => model_loop,
          "exact_secrets" => exact_secrets
        ).value
        candidate, failure_phase, failure_reason, kind, loop_state, secrets = base.values_at(
          "candidate_sha", "phase", "reason", "execution_kind", "model_loop", "exact_secrets")
        [ candidate, failure_phase, failure_reason, kind, loop_state ].each do |value|
          assert!(value.instance_of?(String), "workflow-creator non-passing evidence is invalid")
        end
        detail_value = begin
          captured = Values.capture(detail).value
          if captured.nil?
            nil
          elsif captured.instance_of?(String)
            TextSafety.redact(captured, exact_secrets: secrets, limit: DETAIL_LIMIT)
          else
            OMITTED_DETAIL
          end
        rescue Values::Error, TextSafety::Error
          OMITTED_DETAIL
        end
        candidate = candidate.downcase
        result = Values.capture(
          "schema" => Vocabulary.fetch("evidence_schema"), "schema_version" => 1,
          "platform" => "openclaw", "candidate_sha" => SHA.match?(candidate) ? candidate : "unresolved",
          "result" => "failed", "phase" => failure_phase, "reason" => failure_reason,
          "detail" => detail_value, "execution_kind" => kind, "model_loop" => loop_state,
          "secret_scan" => { "status" => "passed", "scanner" => Vocabulary.fetch("scanner") }
        )
        validate_nonpassing!(result, secrets)
      rescue Values::Error, KeyError
        raise Error, "workflow-creator non-passing evidence is invalid"
      end
      def validate_nonpassing!(snapshot, exact_secrets)
        row = snapshot.value
        schema, scanner = Vocabulary.values_at("evidence_schema", "scanner")
        expected = { "schema" => schema, "schema_version" => 1,
                     "platform" => "openclaw", "result" => "failed",
                     "secret_scan" => { "status" => "passed", "scanner" => scanner } }
        exact!(row, FAILURE, "workflow-creator non-passing evidence is invalid", expected:)
        version, candidate, phase, reason, detail, kind, model = row.values_at(
          "schema_version", "candidate_sha", "phase", "reason", "detail", "execution_kind", "model_loop")
        checks = {
          "types" => [ version.class, candidate.class ] == [ Integer, String ],
          "candidate" => candidate == "unresolved" || SHA.match?(candidate),
          "phase" => FAILURE_PART.match?(phase), "reason" => FAILURE_PART.match?(reason),
          "classification" => CLASSIFICATIONS.include?([ kind, model ])
        }
        assert!(checks.values.all?, "workflow-creator non-passing evidence is invalid")
        if detail
          assert!(detail.instance_of?(String), "workflow-creator non-passing evidence is invalid")
          assert!(detail.bytesize <= DETAIL_LIMIT, "workflow-creator non-passing evidence is invalid")
        end
        secrets!(exact_secrets, texts: [ phase, reason, detail ].compact)
        snapshot
      rescue ArgumentError, IndexError, KeyError, NoMethodError, TypeError, TextSafety::Error
        raise Error, "workflow-creator non-passing evidence is invalid"
      end
      def validate_primary!(row_snapshot, manifest_snapshot, candidate_snapshot, bundle_snapshot)
        row, manifest = row_snapshot.value, manifest_snapshot.value
        candidate_sha, bundle_records = candidate_snapshot.value, bundle_snapshot.value
        exact!(row, PRIMARY_KEYS, "workflow-creator evidence fields are invalid")
        manifest!(manifest, candidate_sha)
        evidence_bundle = row.fetch("evidence_bundle")
        bundles!(bundle_records)
        bundles!(evidence_bundle)
        assert!(Values.capture(evidence_bundle).canonical_bytes == bundle_snapshot.canonical_bytes,
                "workflow-creator evidence bundle is invalid")
        primary_claims!(row, manifest, candidate_sha)
        primary_files!(row)
        summary = { "status" => "passed", "receipt_sha256" => bundle_records.fetch(2).fetch("sha256") }
        assert!(row.values_at("containment", "teardown", "cleanup").all? { |value| value == summary },
                "workflow-creator execution claims are not passing")
        row_snapshot
      rescue ArgumentError, IndexError, KeyError, NoMethodError, TypeError, Values::Error, TextSafety::Error
        raise Error, "workflow-creator contract is invalid"
      end
      def validate_installation!(document_snapshot, kind_snapshot, manifest_snapshot, candidate_snapshot)
        document, kind = document_snapshot.value, kind_snapshot.value
        manifest, candidate_sha = manifest_snapshot.value, candidate_snapshot.value
        exact!(document, INSTALLATION_KEYS, "workflow-creator installed manifest fields are invalid")
        assert!(%w[candidate openclaw].include?(kind), "workflow-creator installed manifest kind is invalid")
        manifest!(manifest, candidate_sha)
        roles = Vocabulary.fetch("member_roles").fetch(kind)
        required, inventory = document.values_at("required_roles", "inventory")
        inventory!(inventory, kind, required, roles)
        required_roles!(required, roles, kind, manifest)
        closure = Values.capture("required_roles" => required, "inventory" => inventory)
        total = inventory.sum { |record| record.fetch("size") }
        installation_identity!(document, kind, manifest, candidate_sha, closure, total)
        document_snapshot
      rescue ArgumentError, IndexError, KeyError, NoMethodError, TypeError, Values::Error, TextSafety::Error
        raise Error, "workflow-creator installed manifest is invalid"
      end
      def secrets!(secrets, texts: [])
        assert!(secrets.instance_of?(Array), "workflow-creator exact secrets are invalid")
        assert!(secrets.length <= 64, "workflow-creator exact secrets are invalid")
        secrets.each do |secret|
          assert!(secret.instance_of?(String), "workflow-creator exact secrets are invalid")
          assert!(secret.bytesize.between?(1, 4_096), "workflow-creator exact secrets are invalid")
        end
        texts.each do |text|
          assert!(TextSafety.secret_findings(text, exact_secrets: secrets).empty?,
                  "workflow-creator non-passing evidence contains secret-shaped material")
        end
      end
      def bundles!(records)
        paths = Vocabulary.fetch("bundle_files").drop(1)
        kinds = %w[candidate_installation openclaw_installation execution_receipt]
        assert!(records.instance_of?(Array), "workflow-creator evidence bundle is invalid")
        assert!(records.length == 3, "workflow-creator evidence bundle is invalid")
        records.each_with_index do |record, index|
          record!(record, BUNDLE_KEYS, "workflow-creator evidence bundle is invalid",
                  path: true, positive: true, binding: [ paths.fetch(index), kinds.fetch(index) ])
        end
      end
      def primary_claims!(row, manifest, candidate_sha)
        schema, activation, commands, graph, task, classification, scanner, prompt, task_prompt = Vocabulary.values_at(
          "evidence_schema", "native_activation", "commands", "graph", "task", "classification", "scanner",
          "prompt", "task_prompt")
        expected = {
          "schema" => schema, "schema_version" => 1, "platform" => "openclaw", "candidate_sha" => candidate_sha,
          "result" => "passed", "skill" => manifest.slice("skill_version", "canonical_digest"),
          "native_activation" => activation, "hive_commands" => commands, "validation" => graph,
          "creation_only_task_count" => 0, "task_count" => 1, "task" => task, "external_actions" => [],
          "secret_scan" => { "status" => "passed", "scanner" => scanner },
          "execution_kind" => classification.fetch("execution_kind"),
          "model_loop" => classification.fetch("model_loop"),
          "prompt_sha256" => Digest::SHA256.hexdigest(prompt),
          "task_prompt_sha256" => Digest::SHA256.hexdigest(task_prompt)
        }
        assert!(row.slice(*expected.keys) == expected, "workflow-creator primary claims are invalid")
        numeric = row.values_at("schema_version", "creation_only_task_count", "task_count")
        numeric << row.dig("task", "run_count")
        assert!(numeric.all? { |value| value.instance_of?(Integer) }, "workflow-creator numeric claims are invalid")
      end
      def primary_files!(row)
        created, instruction = row.values_at("created_files", "executed_instruction")
        assert!(created.instance_of?(Array), "workflow-creator primary files are invalid")
        created.each { |item| record!(item, FILE_KEYS, "workflow-creator file invalid", path: true, positive: true) }
        record!(instruction, FILE_KEYS, "workflow-creator file invalid", path: true, positive: true)
        paths = created.map { |item| item.fetch("path") }
        authored = created.find { |item| item.fetch("path") == Vocabulary.fetch("executed_instruction") }
        assert!(paths == Vocabulary.fetch("files"), "workflow-creator primary files are invalid")
        assert!(instruction == authored, "workflow-creator primary instruction is invalid")
      end
      def inventory!(inventory, kind, required, roles)
        message = "workflow-creator #{kind} installed inventory is invalid"
        assert!(inventory.instance_of?(Array), message)
        assert!(inventory.length.between?(1, MAX_INVENTORY_ENTRIES), message)
        inventory.each { |item| record!(item, FILE_KEYS, message, path: true, positive: false) }
        paths = inventory.map { |item| item.fetch("path") }
        assert!(paths == paths.sort.uniq, message)
        records = required.values
        assert!(records.all? { |item| inventory.include?(item) }, message)
        assert!(records.map { |item| item.fetch("path") }.uniq.length == roles.length, message)
      end
      def required_roles!(required, roles, kind, manifest)
        message = "workflow-creator #{kind} installed required roles are invalid"
        exact!(required, roles, message)
        records = required.values
        records.each { |item| record!(item, FILE_KEYS, message, path: true, positive: false) }
        package = required.fetch("package")
        assert!(package.fetch("size").positive?, message)
        return unless kind == "candidate"
        packages = manifest.fetch("files").select { |name, _item| name.match?(/\Ahive-cli-[0-9].*\.gem\z/) }.values
        assert!(packages.length == 1, message)
        assert!(package.values_at("sha256", "size") == packages.first.values_at("sha256", "size"), message)
      end
      def installation_identity!(document, kind, manifest, candidate_sha, closure, total)
        version, revision, declared_total = document.values_at("version", "schema_version", "total_size")
        schema, scanner = Vocabulary.values_at("installed_schema", "scanner")
        expected_version = kind == "candidate" ? manifest.fetch("hive_version") : version
        expected = {
          "schema" => schema, "schema_version" => 1, "candidate_sha" => candidate_sha, "kind" => kind,
          "version" => expected_version, "closure_sha256" => Digest::SHA256.hexdigest(closure.canonical_bytes),
          "total_size" => total, "secret_scan" => { "status" => "passed", "scanner" => scanner }
        }
        assert!(document.slice(*expected.keys) == expected, "workflow-creator installation identity invalid")
        assert!([ revision, declared_total ].all? { |value| value.instance_of?(Integer) },
                "workflow-creator installed numeric claims are invalid")
        assert!(version.instance_of?(String), "workflow-creator installed version is invalid")
        assert!(!version.empty?, "workflow-creator installed version is invalid")
        assert!(TextSafety.secret_findings(version, exact_secrets: Values.capture([]).value).empty?,
                "workflow-creator installed version contains secret material")
        assert!(total.between?(1, MAX_TOTAL_BYTES), "workflow-creator installed total is invalid")
      end
      def manifest!(manifest, candidate_sha)
        exact!(manifest, MANIFEST, "artifact manifest fields are invalid")
        digest, _candidate, files, version, _schema, revision, skill = manifest.values_at(*MANIFEST)
        expected = { "schema" => "hive-live-agent-candidate-artifacts", "schema_version" => 1,
                     "candidate_sha" => candidate_sha }
        assert!(manifest.slice(*expected.keys) == expected, "workflow-creator evidence identity or result is invalid")
        types = [ candidate_sha, revision, version, skill, digest, files ].map(&:class)
        assert!(types == [ String, Integer, String, String, String, Hash ], "workflow-creator artifact types invalid")
        assert!(SHA.match?(candidate_sha), "workflow-creator candidate identity is invalid")
        assert!([ version, skill ].none?(&:empty?), "workflow-creator artifact versions are invalid")
        assert!(DIGEST.match?(digest), "workflow-creator artifact digest is invalid")
        names = [ "hive-agent-skills-#{candidate_sha}.tar.gz", "hive-cli-#{version}.gem",
                  "hive-source-#{candidate_sha}.tar.gz" ].sort
        assert!(files.keys.sort == names, "workflow-creator evidence identity or result is invalid")
        files.each_value { |item| record!(item, ARTIFACT_KEYS, "artifact file invalid", path: false, positive: true) }
      end
      def record!(value, keys, message, path:, positive:, binding: nil)
        exact!(value, keys, message)
        size, digest = value.values_at("size", "sha256")
        assert!([ digest.class, size.class ] == [ String, Integer ], message)
        assert!(DIGEST.match?(digest), message)
        assert!(TextSafety.safe_relative_path?(value.fetch("path")), message) if path
        if positive
          assert!(size.positive?, message)
        else
          assert!(size.between?(0, MAX_MEMBER_BYTES), message)
        end
        assert!(value.values_at("path", "kind") == binding, message) if binding
      end
      def exact!(value, keys, message, expected: nil)
        assert!(value.instance_of?(Hash), message)
        assert!(value.keys.sort == keys.sort, message)
        assert!(value.slice(*expected.keys) == expected, message) if expected
      end
      def assert!(condition, message)
        raise Error, message unless condition
      end
    end
end
