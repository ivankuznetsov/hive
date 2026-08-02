require "digest"
require_relative "proof_primitives"
module HiveLiveAgentProof
  module WorkflowCreator
    module Contract
      PRIMARY_KEYS = Primitives.deep_freeze(%w[
        schema schema_version platform candidate_sha result prompt_sha256
        task_prompt_sha256 skill native_activation hive_commands created_files
        validation creation_only_task_count task_count task external_actions
        secret_scan execution_kind model_loop executed_instruction evidence_bundle
        containment teardown cleanup])
      FAILURE_KEYS = Primitives.deep_freeze(%w[
        schema schema_version platform candidate_sha result phase reason detail
        execution_kind model_loop secret_scan])
      MANIFEST_KEYS = Primitives.deep_freeze(%w[
        canonical_digest candidate_sha files hive_version schema schema_version
        skill_version])
      INSTALLATION_KEYS = Primitives.deep_freeze(%w[
        schema schema_version candidate_sha kind version closure_sha256
        required_roles inventory total_size secret_scan])
      FILE_KEYS = Primitives.deep_freeze(%w[path sha256 size])
      ARTIFACT_KEYS = Primitives.deep_freeze(%w[sha256 size])
      BUNDLE_KEYS = Primitives.deep_freeze(%w[kind path sha256 size])
      SUMMARY_KEYS = Primitives.deep_freeze(%w[receipt_sha256 status])
      SHA = /\A[0-9a-f]{40}\z/.freeze
      DIGEST = /\A[0-9a-f]{64}\z/.freeze
      FAILURE_PART = /\A[a-z][a-z0-9_]{0,63}\z/.freeze
      CLASSIFICATIONS = Primitives.deep_freeze([
        %w[unavailable not_started],
        %w[deterministic_fixture not_exercised],
        %w[authenticated_openclaw executed]
      ])
      DETAIL_LIMIT, MAX_DETAIL_INPUT_BYTES, MAX_EXACT_SECRETS, PLAIN = 1_000, 4_096, 64, Primitives::PLAIN
      MAX_SECRET_BYTES, MAX_INVENTORY_ENTRIES, MAX_MEMBER_BYTES, MAX_TOTAL_BYTES = 4_096, 512, 268_435_456, 1_073_741_824
      ASSERT = ->(condition, message) { raise Error, message unless condition }.freeze
      module_function
      def failure(candidate_sha:, phase:, reason:, detail: nil,
                  execution_kind: "unavailable", model_loop: "not_started",
                  exact_secrets: [])
        inputs = [ candidate_sha, phase, reason, execution_kind, model_loop ]
        strings_valid = inputs.all? { |value| PLAIN.call(value, String) && value.encoding == Encoding::UTF_8 && value.valid_encoding? }
        strings_valid &&= detail.nil? || (PLAIN.call(detail, String) && detail.encoding == Encoding::UTF_8 && detail.valid_encoding?)
        ASSERT.call(strings_valid, "workflow-creator non-passing evidence is invalid")
        exact_secrets = exact_secrets!(exact_secrets)
        candidate = candidate_sha.downcase
        document = {
          "schema" => Vocabulary.fetch("evidence_schema"),
          "schema_version" => Vocabulary.fetch("schema_version"),
          "platform" => "openclaw",
          "candidate_sha" => SHA.match?(candidate) ? candidate : "unresolved",
          "result" => "failed", "phase" => phase, "reason" => reason,
          "detail" => detail.nil? ? nil : Primitives.secret_safe_text(
            detail, exact_secrets:, limit: DETAIL_LIMIT, input_limit: MAX_DETAIL_INPUT_BYTES
          ),
          "execution_kind" => execution_kind, "model_loop" => model_loop,
          "secret_scan" => { "status" => "passed", "scanner" => Vocabulary.fetch("scanner") }
        }
        validate_nonpassing!(document, exact_secrets:)
      rescue TypeError, ArgumentError, EncodingError
        raise Error, "workflow-creator non-passing evidence is invalid"
      end
      def validate_nonpassing!(row, exact_secrets: [])
        exact_secrets = exact_secrets!(exact_secrets)
        Primitives.canonical_json(row)
        valid = row.instance_of?(Hash) && row.keys.sort == FAILURE_KEYS.sort &&
          row["secret_scan"].instance_of?(Hash) && row["secret_scan"].keys.sort == %w[scanner status] &&
          row["schema"] == Vocabulary.fetch("evidence_schema") &&
          row["schema_version"].instance_of?(Integer) && row["schema_version"] == 1 &&
          row["platform"] == "openclaw" && row["candidate_sha"].instance_of?(String) &&
          (row["candidate_sha"] == "unresolved" || SHA.match?(row["candidate_sha"])) &&
          row["result"] == "failed" && row["phase"].instance_of?(String) && FAILURE_PART.match?(row["phase"]) &&
          row["reason"].instance_of?(String) && FAILURE_PART.match?(row["reason"]) &&
          (row["detail"].nil? || (row["detail"].instance_of?(String) && row["detail"].valid_encoding? &&
            row["detail"].bytesize <= DETAIL_LIMIT)) &&
          CLASSIFICATIONS.include?([ row["execution_kind"], row["model_loop"] ]) &&
          row["secret_scan"] == { "status" => "passed", "scanner" => Vocabulary.fetch("scanner") }
        ASSERT.call(valid, "workflow-creator non-passing evidence is invalid")
        ASSERT.call(Primitives.secret_findings(JSON.generate(row), exact_secrets:).empty?,
                    "workflow-creator non-passing evidence contains secret-shaped material")
        row
      rescue TypeError, NoMethodError, ArgumentError, EncodingError, JSON::GeneratorError
        raise Error, "workflow-creator non-passing evidence is invalid"
      end
      def exact_secrets!(secrets)
        valid = PLAIN.call(secrets, Array) && secrets.length <= MAX_EXACT_SECRETS && secrets.all? do |secret|
          PLAIN.call(secret, String) && secret.encoding == Encoding::UTF_8 && secret.valid_encoding? && secret.bytesize.between?(1, MAX_SECRET_BYTES)
        end
        ASSERT.call(valid, "workflow-creator exact secrets are invalid")
        secrets
      end
      def validate_primary!(row:, manifest:, candidate_sha:, bundle_records:)
        Primitives.canonical_json([ row, manifest, candidate_sha, bundle_records ])
        exact = ->(value, keys) { value.instance_of?(Hash) && value.keys.sort == keys.sort }
        file_record = lambda do |record|
          exact.call(record, FILE_KEYS) && Primitives.safe_relative_path?(record["path"]) &&
            record["sha256"].instance_of?(String) && DIGEST.match?(record["sha256"]) &&
            record["size"].instance_of?(Integer) && record["size"].positive?
        end
        ASSERT.call(exact.call(row, PRIMARY_KEYS), "workflow-creator evidence fields are invalid")
        ASSERT.call(exact.call(manifest, MANIFEST_KEYS), "artifact manifest fields are invalid")
        ASSERT.call(valid_manifest?(manifest, candidate_sha), "workflow-creator evidence identity or result is invalid")
        expected_support = Vocabulary.fetch("bundle_files").drop(1).zip(%w[candidate_installation openclaw_installation execution_receipt])
        bundle_list = lambda do |records|
          records.instance_of?(Array) && records.length == 3 && records.each_with_index.all? do |record, index|
            exact.call(record, BUNDLE_KEYS) &&
              record.values_at("path", "kind") == expected_support.fetch(index) &&
              record["sha256"].instance_of?(String) && DIGEST.match?(record["sha256"]) &&
              record["size"].instance_of?(Integer) && record["size"].positive?
          end
        end
        bundles_valid = bundle_list.call(bundle_records) && bundle_list.call(row["evidence_bundle"])
        ASSERT.call(bundles_valid, "workflow-creator evidence bundle is invalid")
        %w[skill native_activation secret_scan executed_instruction containment teardown cleanup].each do |field|
          keys = { "skill" => %w[canonical_digest skill_version],
                   "native_activation" => %w[invocation kind], "secret_scan" => %w[scanner status],
                   "executed_instruction" => FILE_KEYS }.fetch(field, SUMMARY_KEYS)
          ASSERT.call(exact.call(row[field], keys), "workflow-creator #{field} fields are invalid")
        end
        identity = row["schema"] == Vocabulary.fetch("evidence_schema") &&
          row["schema_version"].instance_of?(Integer) && row["schema_version"] == 1 &&
          row["platform"] == "openclaw" && row["candidate_sha"] == candidate_sha && row["result"] == "passed" &&
          row["skill"] == { "skill_version" => manifest["skill_version"],
                            "canonical_digest" => manifest["canonical_digest"] } &&
          row["native_activation"] == Vocabulary.fetch("native_activation") &&
          row["secret_scan"] == { "status" => "passed", "scanner" => Vocabulary.fetch("scanner") } &&
          row.values_at("execution_kind", "model_loop") == Vocabulary.fetch("classification").values &&
          Primitives.canonical_json(row["evidence_bundle"]) == Primitives.canonical_json(bundle_records)
        ASSERT.call(identity, "workflow-creator evidence identity or result is invalid")
        created = row["created_files"]
        authored = created&.find { |record| record["path"] == Vocabulary.fetch("executed_instruction") }
        content = created.instance_of?(Array) && created.map { |record| record["path"] } == Vocabulary.fetch("files") &&
          created.all? { |record| file_record.call(record) } && file_record.call(row["executed_instruction"]) &&
          row["executed_instruction"] == authored && row["validation"] == Vocabulary.fetch("graph") &&
          row["creation_only_task_count"].instance_of?(Integer) && row["creation_only_task_count"].zero? &&
          row["task_count"].instance_of?(Integer) && row["task_count"] == 1 &&
          row.dig("task", "run_count").instance_of?(Integer) && row["task"] == Vocabulary.fetch("task") &&
          row["external_actions"] == [] && row["prompt_sha256"] == Digest::SHA256.hexdigest(Vocabulary.fetch("prompt")) &&
          row["task_prompt_sha256"] == Digest::SHA256.hexdigest(Vocabulary.fetch("task_prompt")) &&
          row["hive_commands"] == Vocabulary.fetch("commands")
        ASSERT.call(content, "workflow-creator primary claims are invalid")
        summary = { "status" => "passed", "receipt_sha256" => bundle_records.fetch(2).fetch("sha256") }
        ASSERT.call(%w[containment teardown cleanup].all? { |field| row[field] == summary },
                    "workflow-creator execution claims are not passing")
        ASSERT.call(Primitives.secret_findings(JSON.generate(row)).empty?,
                    "workflow-creator evidence contains secret-shaped material")
        row
      rescue KeyError, TypeError, NoMethodError, ArgumentError, EncodingError, JSON::GeneratorError
        raise Error, "workflow-creator contract is invalid"
      end
      def valid_manifest?(manifest, candidate_sha)
        return false unless manifest.instance_of?(Hash) && manifest.keys.sort == MANIFEST_KEYS.sort
        Primitives.canonical_json(manifest)
        version = manifest["hive_version"]
        names = [ "hive-agent-skills-#{candidate_sha}.tar.gz", "hive-cli-#{version}.gem",
                 "hive-source-#{candidate_sha}.tar.gz" ].sort
        records = manifest["files"]
        candidate_sha.instance_of?(String) && SHA.match?(candidate_sha) &&
          manifest["schema"] == "hive-live-agent-candidate-artifacts" &&
          manifest["schema_version"].instance_of?(Integer) && manifest["schema_version"] == 1 &&
          manifest["candidate_sha"] == candidate_sha && version.instance_of?(String) && !version.empty? &&
          manifest["skill_version"].instance_of?(String) && !manifest["skill_version"].empty? &&
          manifest["canonical_digest"].instance_of?(String) && DIGEST.match?(manifest["canonical_digest"]) &&
          records.instance_of?(Hash) && records.keys.sort == names && records.values.all? do |record|
            record.instance_of?(Hash) && record.keys.sort == ARTIFACT_KEYS &&
              record["sha256"].instance_of?(String) && DIGEST.match?(record["sha256"]) &&
              record["size"].instance_of?(Integer) && record["size"].positive?
          end
      rescue Error
        false
      end
      def validate_installation!(document:, kind:, manifest:, candidate_sha:)
        Primitives.canonical_json([ document, kind, manifest, candidate_sha ])
        exact = ->(value, keys) { value.instance_of?(Hash) && value.keys.sort == keys.sort }
        record = lambda do |value|
          exact.call(value, FILE_KEYS) && Primitives.safe_relative_path?(value["path"]) &&
            value["sha256"].instance_of?(String) && DIGEST.match?(value["sha256"]) &&
            value["size"].instance_of?(Integer) && value["size"].between?(0, MAX_MEMBER_BYTES)
        end
        ASSERT.call(exact.call(document, INSTALLATION_KEYS), "workflow-creator installed manifest fields are invalid")
        ASSERT.call(exact.call(manifest, MANIFEST_KEYS), "artifact manifest fields are invalid")
        ASSERT.call(valid_manifest?(manifest, candidate_sha), "workflow-creator installed manifest identity is invalid")
        roles = Vocabulary.fetch("member_roles").fetch(kind)
        inventory = document["inventory"]
        inventory_valid = inventory.instance_of?(Array) && inventory.length.between?(1, MAX_INVENTORY_ENTRIES) &&
          inventory.all? { |item| record.call(item) } &&
          inventory.map { |item| item["path"] }.then { |paths| paths == paths.sort && paths.uniq == paths }
        ASSERT.call(inventory_valid, "workflow-creator #{kind} installed inventory is invalid")
        required = document["required_roles"]
        ASSERT.call(exact.call(required, roles), "workflow-creator #{kind} installed required roles are invalid")
        roles_valid = required.values.all? { |item| record.call(item) && inventory.include?(item) } &&
          required.values.map { |item| item["path"] }.uniq.length == roles.length &&
          required.fetch("package").fetch("size").positive?
        ASSERT.call(roles_valid, "workflow-creator #{kind} installed required roles are not inventory-bound")
        closure = { "required_roles" => required, "inventory" => inventory }
        total = inventory.sum { |item| item.fetch("size") }
        version_valid = kind == "candidate" ? document["version"] == manifest["hive_version"] :
          document["version"].instance_of?(String) && !document["version"].empty?
        valid = candidate_sha.instance_of?(String) && SHA.match?(candidate_sha) && document["schema"] == Vocabulary.fetch("installed_schema") &&
          document["schema_version"].instance_of?(Integer) && document["schema_version"] == 1 &&
          document["candidate_sha"] == candidate_sha && document["kind"] == kind && version_valid &&
          document["closure_sha256"] == Digest::SHA256.hexdigest(Primitives.canonical_json(closure)) &&
          document["total_size"].instance_of?(Integer) && document["total_size"] == total && total.between?(1, MAX_TOTAL_BYTES) &&
          document["secret_scan"] == { "status" => "passed", "scanner" => Vocabulary.fetch("scanner") }
        ASSERT.call(valid, "workflow-creator #{kind} installed manifest identity is invalid")
        if kind == "candidate"
          packages = manifest.fetch("files").select { |name, _item| name.match?(/\Ahive-cli-[0-9].*\.gem\z/) }.values
          package = required.fetch("package")
          ASSERT.call(packages.one? && package.values_at("sha256", "size") == packages.first.values_at("sha256", "size"),
                      "workflow-creator candidate installed package does not match the release artifact")
        end
        ASSERT.call(Primitives.secret_findings(JSON.generate(document)).empty?,
                    "workflow-creator installed manifest contains secret-shaped material")
        document
      rescue KeyError, TypeError, NoMethodError, ArgumentError, EncodingError, JSON::GeneratorError
        raise Error, "workflow-creator installed manifest is invalid"
      end
    end
  end
end
