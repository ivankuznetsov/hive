module HiveLiveAgentProof
  WORKFLOW_CREATOR_REQUEST =
    "Create a three-stage editorial workflow that researches, drafts, and requires approval before publishing.".freeze
  WORKFLOW_CREATOR_PROMPT = <<~PROMPT.freeze
    /hive
    #{WORKFLOW_CREATOR_REQUEST}
    Use the installed Hive workflow-creator capability in this initialized project.
    This is creation-only: validate the result, report the defaults, and do not create or run a task.
  PROMPT
  WORKFLOW_CREATOR_TASK_REQUEST = "Research and draft the launch announcement for approval.".freeze
  WORKFLOW_CREATOR_TASK_KEY = "workflow-creator-proof:editorial:live-proof".freeze
  WORKFLOW_CREATOR_TASK_SLUG = "editorial-live-proof".freeze
  WORKFLOW_CREATOR_TASK_PROMPT = <<~PROMPT.freeze
    /hive
    Use the validated editorial workflow to create and run one task for:
    "#{WORKFLOW_CREATOR_TASK_REQUEST}"
    Use idempotency key #{WORKFLOW_CREATOR_TASK_KEY}. In this exact order: create the task,
    run its first stage once, repeat the same creation command once to prove the retry is a no-op,
    then query operational status. Do not publish or perform any other external action.
  PROMPT
  WORKFLOW_CREATOR_TASK_NEW_ARGV = [
    "new", "workflow-creator-proof", "--workflow", "editorial",
    "--idempotency-key", WORKFLOW_CREATOR_TASK_KEY, "--json", WORKFLOW_CREATOR_TASK_REQUEST
  ].freeze
  WORKFLOW_CREATOR_COMMANDS = [
    [ "version" ],
    [ "workflow", "list", "--json" ],
    [ "workflow", "new", "editorial", "--json" ],
    [ "workflow", "validate", "editorial", "--json" ],
    [ "workflow", "commit", "editorial" ],
    WORKFLOW_CREATOR_TASK_NEW_ARGV,
    [ "run", WORKFLOW_CREATOR_TASK_SLUG ],
    WORKFLOW_CREATOR_TASK_NEW_ARGV,
    [ "status", "--operational", "--json" ]
  ].freeze
  WORKFLOW_CREATOR_FILES = [
    ".hive-state/workflows/editorial.yml",
    ".hive-state/workflows/editorial/draft.md",
    ".hive-state/workflows/editorial/research.md"
  ].freeze
  WORKFLOW_CREATOR_EXECUTED_INSTRUCTION =
    ".hive-state/workflows/editorial/research.md".freeze

  class WorkflowCreatorContract
    EVIDENCE_SCHEMA = "hive-live-workflow-creator-evidence".freeze
    FAILURE_KEYS = %w[
      schema schema_version platform candidate_sha result phase reason detail
      execution_kind model_loop secret_scan
    ].freeze
    SUCCESS_KEYS = %w[
      schema schema_version platform candidate_sha result prompt_sha256
      task_prompt_sha256 skill native_activation hive_commands created_files
      validation creation_only_task_count task_count task external_actions
      secret_scan cleanup execution_kind model_loop executed_instruction
      evidence_bundle containment teardown
    ].freeze
    FAILURE_PART = /\A[a-z][a-z0-9_]{0,63}\z/.freeze
    CLASSIFICATIONS = [
      [ "unavailable", "not_started" ],
      [ "deterministic_fixture", "not_exercised" ],
      [ "authenticated_openclaw", "executed" ]
    ].freeze
    LIVE_CLASSIFICATION = [ "authenticated_openclaw", "executed" ].freeze
    ARTIFACT_SCHEMA = "hive-live-agent-candidate-artifacts".freeze
    SCANNER = "hive-live-agent-proof/v1".freeze
    DETAIL_LIMIT = 1_000

    class << self
      def initial(candidate_sha:)
        failure(
          candidate_sha: candidate_sha,
          phase: "preflight",
          reason: "not_started"
        )
      end

      def terminal_failure(candidate_sha:, proof_succeeded:,
                           model_loop_executed:, detail: nil,
                           exact_secrets: [])
        unless [ true, false ].include?(proof_succeeded) &&
               [ true, false ].include?(model_loop_executed) &&
               (!proof_succeeded || model_loop_executed)
          fail_contract!("workflow-creator terminal state is invalid")
        end

        phase, reason =
          if proof_succeeded
            [ "evidence", "u14_execution_custody_unavailable" ]
          elsif model_loop_executed
            [ "proof", "proof_failed" ]
          else
            [ "preflight", "proof_failed" ]
          end
        execution_kind, model_loop =
          model_loop_executed ? LIVE_CLASSIFICATION : CLASSIFICATIONS.first
        failure(
          candidate_sha: candidate_sha,
          phase: phase,
          reason: reason,
          detail: detail,
          execution_kind: execution_kind,
          model_loop: model_loop,
          exact_secrets: exact_secrets
        )
      end

      def failure(candidate_sha:, phase:, reason:, detail: nil,
                  execution_kind: "unavailable", model_loop: "not_started",
                  exact_secrets: [])
        bounded_detail =
          unless detail.nil?
            sanitize(
              detail.to_s.scrub,
              exact_secrets: exact_secrets
            ).byteslice(0, DETAIL_LIMIT).to_s.scrub
          end
        document = {
          "schema" => EVIDENCE_SCHEMA,
          "schema_version" => SCHEMA_VERSION,
          "platform" => "openclaw",
          "candidate_sha" => normalized_failure_candidate(candidate_sha),
          "result" => "failed",
          "phase" => phase.to_s,
          "reason" => reason.to_s,
          "detail" => bounded_detail,
          "execution_kind" => execution_kind.to_s,
          "model_loop" => model_loop.to_s,
          "secret_scan" => {
            "status" => "passed",
            "scanner" => SCANNER
          }
        }
        sanitized = sanitize(document, exact_secrets: exact_secrets)
        validate_nonpassing!(sanitized)
        sanitized
      end

      def validate_nonpassing!(row)
        exact_hash!(row, FAILURE_KEYS, "workflow-creator non-passing evidence")
        valid =
          row["schema"] == EVIDENCE_SCHEMA &&
          row["schema_version"] == SCHEMA_VERSION &&
          row["platform"] == "openclaw" &&
          row["result"] == "failed" &&
          (row["candidate_sha"] == "unresolved" || SAFE_SHA.match?(row["candidate_sha"].to_s)) &&
          FAILURE_PART.match?(row["phase"].to_s) &&
          FAILURE_PART.match?(row["reason"].to_s) &&
          (
            row["detail"].nil? ||
            (row["detail"].is_a?(String) &&
             row["detail"].bytesize <= DETAIL_LIMIT)
          ) &&
          CLASSIFICATIONS.include?([ row["execution_kind"], row["model_loop"] ]) &&
          row["secret_scan"] == { "status" => "passed", "scanner" => SCANNER }
        fail_contract!("workflow-creator non-passing evidence is invalid") unless valid
        reject_secrets!(row, "workflow-creator non-passing evidence")
        row
      end

      def validate_success_supporting!(row:, manifest:, candidate_sha:,
                                       bundle_dir:, exact_secrets: [])
        validate_success_document!(
          row: row,
          manifest: manifest,
          candidate_sha: candidate_sha
        )
        WorkflowCreatorBundle.validate_supporting!(
          directory: bundle_dir,
          row: row,
          manifest: manifest,
          candidate_sha: candidate_sha,
          exact_secrets: exact_secrets
        )
      rescue KeyError, TypeError, NoMethodError, ArgumentError => e
        raise Error, "workflow-creator contract is invalid: #{e.message}"
      end

      def validate_success!(row:, manifest:, candidate_sha:, bundle_dir:,
                            exact_secrets: [])
        validate_success_document!(
          row: row,
          manifest: manifest,
          candidate_sha: candidate_sha
        )
        WorkflowCreatorBundle.validate!(
          directory: bundle_dir,
          row: row,
          manifest: manifest,
          candidate_sha: candidate_sha,
          exact_secrets: exact_secrets
        )
      rescue KeyError, TypeError, NoMethodError, ArgumentError => e
        raise Error, "workflow-creator contract is invalid: #{e.message}"
      end

      def canonical_json(document)
        "#{JSON.pretty_generate(document)}\n"
      end

      def sanitize(value, exact_secrets: [])
        case value
        when Hash
          value.to_h { |key, nested| [ key, sanitize(nested, exact_secrets: exact_secrets) ] }
        when Array
          value.map { |nested| sanitize(nested, exact_secrets: exact_secrets) }
        when String
          sanitized = value.dup
          exact_secrets.each do |secret|
            sanitized.gsub!(secret.to_s, "[REDACTED]") unless secret.to_s.empty?
          end
          SECRET_PATTERNS.each { |pattern| sanitized.gsub!(pattern, "[REDACTED]") }
          sanitized
        else
          value
        end
      end

      private

      def validate_success_document!(row:, manifest:, candidate_sha:)
        exact_hash!(row, SUCCESS_KEYS, "workflow-creator evidence")
        validate_identity!(row, manifest, candidate_sha)
        validate_prompt_and_commands!(row)
        validate_created_files!(row)
        validate_graph!(row)
        validate_task!(row)
        validate_execution_claims!(row)
        reject_secrets!(row, "workflow-creator evidence")
        row
      end

      def normalized_failure_candidate(candidate_sha)
        value = candidate_sha.to_s.downcase
        SAFE_SHA.match?(value) ? value : "unresolved"
      end

      def validate_identity!(row, manifest, candidate_sha)
        exact_hash!(manifest, %w[
          canonical_digest candidate_sha files hive_version schema
          schema_version skill_version
        ], "artifact manifest")
        exact_hash!(row["skill"], %w[canonical_digest skill_version], "workflow-creator skill")
        exact_hash!(
          row["secret_scan"],
          %w[scanner status],
          "workflow-creator secret scan"
        )
        valid =
          SAFE_SHA.match?(candidate_sha.to_s) &&
          manifest["schema"] == ARTIFACT_SCHEMA &&
          manifest["schema_version"] == SCHEMA_VERSION &&
          manifest["candidate_sha"] == candidate_sha &&
          manifest["files"].is_a?(Hash) &&
          manifest["hive_version"].is_a?(String) &&
          !manifest["hive_version"].empty? &&
          manifest["skill_version"].is_a?(String) &&
          !manifest["skill_version"].empty? &&
          /\A[0-9a-f]{64}\z/.match?(manifest["canonical_digest"].to_s) &&
          row["schema"] == EVIDENCE_SCHEMA &&
          row["schema_version"] == SCHEMA_VERSION &&
          row["platform"] == "openclaw" &&
          row["candidate_sha"] == candidate_sha &&
          row["result"] == "passed" &&
          row["skill"] == {
            "skill_version" => manifest["skill_version"],
            "canonical_digest" => manifest["canonical_digest"]
          } &&
          HiveLiveAgentProof.valid_native_activation?(
            "openclaw", row["native_activation"]
          ) &&
          row["secret_scan"] == { "status" => "passed", "scanner" => SCANNER } &&
          [ row["execution_kind"], row["model_loop"] ] == LIVE_CLASSIFICATION
        fail_contract!("workflow-creator evidence identity or result is invalid") unless valid
      end

      def validate_prompt_and_commands!(row)
        valid =
          row["prompt_sha256"] == Digest::SHA256.hexdigest(WORKFLOW_CREATOR_PROMPT) &&
          row["task_prompt_sha256"] ==
            Digest::SHA256.hexdigest(WORKFLOW_CREATOR_TASK_PROMPT) &&
          row["hive_commands"] == WORKFLOW_CREATOR_COMMANDS
        fail_contract!("workflow-creator prompt or command sequence is invalid") unless valid
      end

      def validate_created_files!(row)
        created = row["created_files"]
        valid =
          created.is_a?(Array) &&
          created.map { |record| record["path"] }.sort == WORKFLOW_CREATOR_FILES &&
          created.all? { |record| valid_file_record?(record) }
        fail_contract!("workflow-creator created-file records are invalid") unless valid

        executed = row["executed_instruction"]
        authored = created.find do |record|
          record["path"] == WORKFLOW_CREATOR_EXECUTED_INSTRUCTION
        end
        unless valid_file_record?(executed) &&
               executed["path"] == WORKFLOW_CREATOR_EXECUTED_INSTRUCTION &&
               executed == authored
          fail_contract!("workflow-creator authored and executed instructions do not match")
        end
      end

      def validate_graph!(row)
        validation = row["validation"]
        exact_hash!(
          validation,
          %w[automatic_edges human_outcomes stages valid],
          "workflow-creator validation"
        )
        valid =
          validation["valid"] == true &&
          validation["stages"] == %w[research draft approval] &&
          validation["automatic_edges"] == [
            %w[research draft],
            %w[draft approval]
          ] &&
          validation["human_outcomes"] == [
            {
              "stage" => "approval", "name" => "approve", "complete" => true,
              "artifact" => "draft.md", "to" => nil
            },
            {
              "stage" => "approval", "name" => "reject", "complete" => false,
              "artifact" => nil, "to" => "draft"
            }
          ]
        fail_contract!("workflow-creator normalized graph is invalid") unless valid
      end

      def validate_task!(row)
        expected = {
          "slug" => WORKFLOW_CREATOR_TASK_SLUG,
          "workflow" => "editorial",
          "first_created" => true,
          "retry_created" => false,
          "run_count" => 1,
          "current_stage" => "1-research"
        }
        valid =
          row["creation_only_task_count"] == 0 &&
          row["task_count"] == 1 &&
          row["task"] == expected
        fail_contract!("workflow-creator proof contains an unauthorized side effect") unless valid
      end

      def validate_execution_claims!(row)
        %w[cleanup containment teardown].each do |field|
          exact_hash!(row[field], %w[status], "workflow-creator #{field}")
        end
        valid =
          row["external_actions"] == [] &&
          row["cleanup"] == { "status" => "passed" } &&
          row["containment"] == { "status" => "passed" } &&
          row["teardown"] == { "status" => "passed" }
        fail_contract!("workflow-creator execution claims are not passing") unless valid
      end

      def valid_file_record?(record)
        record.is_a?(Hash) &&
          record.keys.sort == %w[path sha256 size] &&
          HiveLiveAgentProof.safe_relative_path?(record["path"]) &&
          /\A[0-9a-f]{64}\z/.match?(record["sha256"].to_s) &&
          record["size"].is_a?(Integer) &&
          record["size"].positive?
      end

      def exact_hash!(value, keys, label)
        unless value.is_a?(Hash) && value.keys.sort == keys.sort
          fail_contract!("#{label} fields are invalid")
        end
      end

      def reject_secrets!(value, label)
        findings = HiveLiveAgentProof.secret_findings(JSON.generate(value))
        fail_contract!("#{label} contains secret-shaped material") unless findings.empty?
      end

      def fail_contract!(message)
        raise Error, message
      end
    end
  end

  class WorkflowCreatorBundle
    PRIMARY_NAME = "openclaw-workflow-creator.json".freeze
    ENTRY_SPECS = [
      [ "candidate_installation", "candidate-installed-manifest.json" ],
      [ "openclaw_installation", "openclaw-installed-manifest.json" ],
      [ "execution_receipt", "execution-receipt.json" ]
    ].freeze
    FILENAMES = [ PRIMARY_NAME, *ENTRY_SPECS.map(&:last) ].freeze
    ENTRY_KEYS = %w[kind path sha256 size].freeze
    INSTALLED_MANIFEST_SCHEMA =
      "hive-live-workflow-creator-installed-manifest".freeze
    EXECUTION_RECEIPT_SCHEMA =
      "hive-live-workflow-creator-execution-receipt".freeze
    MAX_FILE_BYTES = 1_048_576
    MAX_TOTAL_BYTES = 2_097_152
    MAX_INVENTORY_ENTRIES = 512
    MAX_INSTALLED_FILE_BYTES = 268_435_456
    MAX_INSTALLED_TOTAL_BYTES = 1_073_741_824

    class Snapshot
      def initialize(bytes:)
        @bytes = bytes.to_h do |name, content|
          [ name, content.dup.force_encoding(Encoding::BINARY).freeze ]
        end.freeze
      end

      def copy_to!(destination)
        FileUtils.mkdir_p(destination, mode: 0o700)
        WorkflowCreatorBundle::FILENAMES.each do |name|
          File.open(
            File.join(destination, name),
            File::WRONLY | File::CREAT | File::EXCL,
            0o600
          ) do |file|
            file.binmode
            file.write(@bytes.fetch(name))
          end
        end
        destination
      end
    end

    class << self
      def load_primary!(directory)
        root = File.expand_path(directory)
        validate_root!(root)
        validate_bundle_inventory!(root)
        parse_canonical!(
          read_regular!(root, PRIMARY_NAME),
          PRIMARY_NAME
        )
      rescue SystemCallError, JSON::ParserError => e
        raise Error, "cannot validate workflow-creator evidence bundle: #{e.message}"
      end

      def validate!(directory:, row:, manifest:, candidate_sha:,
                    exact_secrets: [])
        snapshot = validate_supporting!(
          directory: directory,
          row: row,
          manifest: manifest,
          candidate_sha: candidate_sha,
          exact_secrets: exact_secrets
        )
        primary = read_regular!(File.expand_path(directory), PRIMARY_NAME)
        if primary != WorkflowCreatorContract.canonical_json(row)
          raise Error,
                "workflow-creator primary evidence bytes do not match attestation"
        end
        snapshot
      end

      def validate_supporting!(directory:, row:, manifest:, candidate_sha:,
                               exact_secrets: [])
        root = File.expand_path(directory)
        validate_root!(root)
        validate_bundle_inventory!(root)
        assert_regular!(root, PRIMARY_NAME)
        primary = WorkflowCreatorContract.canonical_json(row)
        if primary.bytesize > MAX_FILE_BYTES
          raise Error, "workflow-creator evidence bundle entry is oversized: #{PRIMARY_NAME}"
        end
        records = row["evidence_bundle"]
        unless records.is_a?(Array) && records.length == ENTRY_SPECS.length
          raise Error, "workflow-creator evidence-bundle records are invalid"
        end
        bytes_by_name = { PRIMARY_NAME => primary }
        documents = {}
        ENTRY_SPECS.each_with_index do |(kind, path), index|
          record = records[index]
          unless record.is_a?(Hash) && record.keys.sort == ENTRY_KEYS &&
                 record["kind"] == kind && record["path"] == path &&
                 record["size"].is_a?(Integer) && record["size"].positive? &&
                 record["size"] <= MAX_FILE_BYTES &&
                 /\A[0-9a-f]{64}\z/.match?(record["sha256"].to_s)
            raise Error, "workflow-creator evidence-bundle records are invalid"
          end
          bytes = read_regular!(root, path)
          unless bytes.bytesize == record["size"] &&
                 Digest::SHA256.hexdigest(bytes) == record["sha256"]
            raise Error, "workflow-creator evidence-bundle digest or size mismatch"
          end
          bytes_by_name[path] = bytes
          documents[path] = parse_canonical!(bytes, path)
        end
        total = bytes_by_name.values.sum(&:bytesize)
        raise Error, "workflow-creator evidence bundle is oversized" if total > MAX_TOTAL_BYTES

        validate_installation!(
          documents.fetch("candidate-installed-manifest.json"),
          kind: "candidate",
          candidate_sha: candidate_sha,
          artifact_manifest: manifest
        )
        validate_installation!(
          documents.fetch("openclaw-installed-manifest.json"),
          kind: "openclaw",
          candidate_sha: candidate_sha,
          artifact_manifest: manifest
        )
        validate_execution_receipt!(
          documents.fetch("execution-receipt.json"),
          row: row,
          candidate_sha: candidate_sha
        )
        bytes_by_name.each do |_name, bytes|
          findings = HiveLiveAgentProof.secret_findings(
            bytes,
            exact_secrets: exact_secrets
          )
          unless findings.empty?
            raise Error, "workflow-creator evidence bundle contains secret-shaped material"
          end
        end
        Snapshot.new(bytes: bytes_by_name)
      rescue SystemCallError, JSON::ParserError => e
        raise Error, "cannot validate workflow-creator evidence bundle: #{e.message}"
      end

      private

      def validate_root!(root)
        stat = File.lstat(root)
        unless stat.directory? && !stat.symlink? && stat.uid == Process.uid
          raise Error, "workflow-creator evidence bundle is not a regular directory"
        end
      end

      def validate_bundle_inventory!(root)
        entries = []
        Dir.each_child(root) do |name|
          entries << name
          if entries.length > FILENAMES.length
            raise Error, "workflow-creator evidence bundle inventory is invalid"
          end
        end
        unless entries.sort == FILENAMES.sort
          raise Error, "workflow-creator evidence bundle inventory is invalid"
        end
      end

      def assert_regular!(root, name)
        path = File.join(root, name)
        stat = File.lstat(path)
        unless stat.file? && !stat.symlink? && stat.nlink == 1 &&
               stat.uid == Process.uid && stat.size <= MAX_FILE_BYTES
          raise Error, "workflow-creator evidence bundle entry is unsafe or oversized: #{name}"
        end
        stat
      end

      def read_regular!(root, name)
        path = File.join(root, name)
        stat = assert_regular!(root, name)
        flags = File::RDONLY
        flags |= File::NOFOLLOW if File.const_defined?(:NOFOLLOW)
        File.open(path, flags) do |file|
          opened = file.stat
          unless opened.dev == stat.dev && opened.ino == stat.ino &&
                 opened.file? && opened.nlink == 1 &&
                 opened.uid == Process.uid
            raise Error, "workflow-creator evidence bundle entry changed while opening: #{name}"
          end
          bytes = file.read(MAX_FILE_BYTES + 1) || "".b
          if bytes.bytesize > MAX_FILE_BYTES
            raise Error, "workflow-creator evidence bundle entry is unsafe or oversized: #{name}"
          end
          bytes
        end
      rescue SystemCallError => e
        raise Error, "cannot read workflow-creator evidence bundle entry #{name}: #{e.message}"
      end

      def parse_canonical!(bytes, name)
        document = JSON.parse(bytes)
        unless bytes == WorkflowCreatorContract.canonical_json(document)
          raise Error, "workflow-creator evidence bundle entry is not canonical JSON: #{name}"
        end
        document
      end

      def validate_installation!(document, kind:, candidate_sha:, artifact_manifest:)
        exact_hash!(
          document,
          %w[schema schema_version installation candidate_sha identity inventory],
          "installed manifest"
        )
        unless document["schema"] == INSTALLED_MANIFEST_SCHEMA &&
               document["schema_version"] == SCHEMA_VERSION &&
               document["installation"] == kind &&
               document["candidate_sha"] == candidate_sha
          raise Error, "workflow-creator installed-manifest identity is invalid"
        end
        validate_inventory!(document["inventory"])
        if kind == "candidate"
          validate_candidate_identity!(document["identity"], artifact_manifest)
        else
          validate_openclaw_identity!(document["identity"])
        end
      end

      def validate_candidate_identity!(identity, manifest)
        exact_hash!(
          identity,
          %w[kind name version artifact_sha256 artifact_size],
          "candidate installation identity"
        )
        gem_name, gem_record = manifest.fetch("files").find do |name, _record|
          name.match?(/\Ahive-cli-[0-9].*\.gem\z/)
        end
        valid =
          gem_name &&
          identity == {
            "kind" => "candidate_gem",
            "name" => "hive-cli",
            "version" => manifest["hive_version"],
            "artifact_sha256" => gem_record["sha256"],
            "artifact_size" => gem_record["size"]
          }
        raise Error, "workflow-creator candidate installation is not artifact-bound" unless valid
      end

      def validate_openclaw_identity!(identity)
        exact_hash!(
          identity,
          %w[kind name version integrity lock_sha256 package_count],
          "OpenClaw installation identity"
        )
        valid =
          identity["kind"] == "openclaw_npm" &&
          identity["name"] == "openclaw" &&
          bounded_string?(identity["version"], 128) &&
          bounded_string?(identity["integrity"], 512) &&
          /\A[0-9a-f]{64}\z/.match?(identity["lock_sha256"].to_s) &&
          identity["package_count"].is_a?(Integer) &&
          identity["package_count"].between?(1, 4096)
        raise Error, "workflow-creator OpenClaw installation identity is invalid" unless valid
      end

      def validate_inventory!(inventory)
        unless inventory.is_a?(Array) &&
               inventory.length.between?(1, MAX_INVENTORY_ENTRIES)
          raise Error, "workflow-creator installed inventory is invalid"
        end
        paths = inventory.map do |record|
          unless record.is_a?(Hash) &&
                 record.keys.sort == %w[path sha256 size] &&
                 HiveLiveAgentProof.safe_relative_path?(record["path"]) &&
                 /\A[0-9a-f]{64}\z/.match?(record["sha256"].to_s) &&
                 record["size"].is_a?(Integer) &&
                 record["size"].between?(0, MAX_INSTALLED_FILE_BYTES)
            raise Error, "workflow-creator installed inventory is invalid"
          end
          record["path"]
        end
        unless paths == paths.sort && paths.uniq.length == paths.length
          raise Error, "workflow-creator installed inventory order is invalid"
        end
        total = inventory.sum { |record| record["size"] }
        if total > MAX_INSTALLED_TOTAL_BYTES
          raise Error, "workflow-creator installed inventory is oversized"
        end
      end

      def validate_execution_receipt!(receipt, row:, candidate_sha:)
        exact_hash!(
          receipt,
          %w[
            schema schema_version candidate_sha result execution_kind model_loop
            installed_manifests hive_commands executed_instruction
            external_actions containment teardown cleanup
          ],
          "execution receipt"
        )
        valid =
          receipt["schema"] == EXECUTION_RECEIPT_SCHEMA &&
          receipt["schema_version"] == SCHEMA_VERSION &&
          receipt["candidate_sha"] == candidate_sha &&
          receipt["result"] == "passed" &&
          receipt["execution_kind"] == "deterministic_fixture" &&
          receipt["model_loop"] == "not_exercised" &&
          receipt["installed_manifests"] == row["evidence_bundle"].first(2) &&
          receipt["hive_commands"] == row["hive_commands"] &&
          receipt["executed_instruction"] == row["executed_instruction"] &&
          receipt["external_actions"] == row["external_actions"] &&
          receipt["containment"] == row["containment"] &&
          receipt["teardown"] == row["teardown"] &&
          receipt["cleanup"] == row["cleanup"]
        raise Error, "workflow-creator execution receipt is inconsistent" unless valid
      end

      def exact_hash!(value, keys, label)
        unless value.is_a?(Hash) && value.keys.sort == keys.sort
          raise Error, "workflow-creator #{label} fields are invalid"
        end
      end

      def bounded_string?(value, max)
        value.is_a?(String) && !value.empty? && value.bytesize <= max
      end
    end
  end
end
