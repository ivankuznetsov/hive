require "digest"
require "fileutils"
require "json"
require_relative "proof_primitives"
require_relative "workflow_creator_vocabulary"
require_relative "workflow_creator_execution_contract"

module HiveLiveAgentProof
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
      evidence_bundle containment teardown provider transport credential_boundary
    ].freeze
    FAILURE_PART = /\A[a-z][a-z0-9_]{0,63}\z/.freeze
    CLASSIFICATIONS = [
      [ "unavailable", "not_started" ],
      [ "deterministic_fixture", "not_exercised" ],
      [ "authenticated_openclaw", "executed" ]
    ].freeze
    LIVE_CLASSIFICATION = [ "authenticated_openclaw", "executed" ].freeze
    ARTIFACT_SCHEMA = "hive-live-agent-candidate-artifacts".freeze
    SCANNER = WORKFLOW_CREATOR_SCANNER
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
        bounded_detail = bounded_detail(detail, exact_secrets: exact_secrets)
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
          exact_secrets: exact_secrets,
          owner_private: true
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
      rescue JSON::GeneratorError => e
        raise Error,
              "workflow-creator document cannot be canonicalized: #{e.message}"
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

      def bounded_detail(detail, exact_secrets:)
        return if detail.nil?

        normalized = detail.to_s.encode(
          Encoding::UTF_8,
          invalid: :replace,
          undef: :replace,
          replace: "\uFFFD"
        )
        sanitized = sanitize(normalized, exact_secrets: exact_secrets)
        return sanitized if sanitized.bytesize <= DETAIL_LIMIT

        sanitized.byteslice(0, DETAIL_LIMIT)
                 .force_encoding(Encoding::UTF_8)
                 .scrub("")
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
          exact_hash!(
            row[field],
            %w[receipt_sha256 status],
            "workflow-creator #{field}"
          )
        end
        valid =
          row["external_actions"] == [] &&
          %w[cleanup containment teardown].all? do |field|
            row.dig(field, "status") == "passed" &&
              /\A[0-9a-f]{64}\z/.match?(
                row.dig(field, "receipt_sha256").to_s
              )
          end
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
    EXECUTION_RECEIPT_SCHEMA = WORKFLOW_CREATOR_EXECUTION_RECEIPT_SCHEMA
    MAX_FILE_BYTES = 1_048_576
    MAX_TOTAL_BYTES = 2_097_152
    MAX_INVENTORY_ENTRIES = 512
    MAX_INSTALLED_FILE_BYTES = 268_435_456
    MAX_INSTALLED_TOTAL_BYTES = 1_073_741_824
    REQUIRED_MEMBER_KEYS = %w[
      executable interpreter_or_launcher lock package
    ].freeze
    CANDIDATE_REQUIRED_MEMBER_KEYS = %w[
      audit_gateway executable interpreter_or_launcher lock package
    ].freeze
    FILE_RECORD_KEYS = %w[path sha256 size].freeze

    class Snapshot
      attr_reader :root_identity

      def initialize(bytes:, root_identity:)
        @bytes = bytes.to_h do |name, content|
          [ name, content.dup.force_encoding(Encoding::BINARY).freeze ]
        end.freeze
        @root_identity = root_identity.freeze
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
      def installed_closure_sha256(required_members:, inventory:)
        member_keys = required_members.keys.sort
        unless [ REQUIRED_MEMBER_KEYS, CANDIDATE_REQUIRED_MEMBER_KEYS ]
               .include?(member_keys)
          raise Error, "workflow-creator installed required members are invalid"
        end
        ordered_members = member_keys.to_h do |key|
          record = required_members.fetch(key)
          [ key, FILE_RECORD_KEYS.to_h { |field| [ field, record.fetch(field) ] } ]
        end
        ordered_inventory = inventory.map do |record|
          FILE_RECORD_KEYS.to_h { |field| [ field, record.fetch(field) ] }
        end
        Digest::SHA256.hexdigest(
          WorkflowCreatorContract.canonical_json(
            {
              "required_members" => ordered_members,
              "inventory" => ordered_inventory
            }
          )
        )
      end

      def load_primary!(directory)
        root = File.expand_path(directory)
        validate_root!(root)
        validate_bundle_inventory!(root)
        parse_canonical!(
          read_regular!(root, PRIMARY_NAME),
          PRIMARY_NAME
        )
      rescue SystemCallError => e
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
                               exact_secrets: [], owner_private: false)
        root = File.expand_path(directory)
        root_stat = validate_root!(root, owner_private: owner_private)
        validate_bundle_inventory!(root)
        assert_regular!(root, PRIMARY_NAME, owner_private: owner_private)
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
          bytes = read_regular!(root, path, owner_private: owner_private)
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
          candidate_sha: candidate_sha,
          candidate_installation:
            documents.fetch("candidate-installed-manifest.json"),
          openclaw_installation:
            documents.fetch("openclaw-installed-manifest.json")
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
        Snapshot.new(
          bytes: bytes_by_name,
          root_identity: {
            dev: root_stat.dev,
            ino: root_stat.ino,
            uid: root_stat.uid
          }
        )
      rescue SystemCallError => e
        raise Error, "cannot validate workflow-creator evidence bundle: #{e.message}"
      end

      private

      def validate_root!(root, owner_private: false)
        stat = File.lstat(root)
        valid = stat.directory? && !stat.symlink? && stat.uid == Process.uid
        valid &&= (stat.mode & 0o777) == 0o700 if owner_private
        unless valid
          raise Error, "workflow-creator evidence bundle is not a regular directory"
        end
        stat
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

      def assert_regular!(root, name, owner_private: false)
        path = File.join(root, name)
        stat = File.lstat(path)
        valid = stat.file? && !stat.symlink? && stat.nlink == 1 &&
                stat.uid == Process.uid && stat.size <= MAX_FILE_BYTES
        valid &&= (stat.mode & 0o777) == 0o600 if owner_private
        unless valid
          raise Error, "workflow-creator evidence bundle entry is unsafe or oversized: #{name}"
        end
        stat
      end

      def read_regular!(root, name, owner_private: false)
        path = File.join(root, name)
        stat = assert_regular!(root, name, owner_private: owner_private)
        flags = File::RDONLY
        flags |= File::NOFOLLOW if File.const_defined?(:NOFOLLOW)
        File.open(path, flags) do |file|
          opened = file.stat
          unless opened.dev == stat.dev && opened.ino == stat.ino &&
                 opened.file? && opened.nlink == 1 &&
                 opened.uid == Process.uid &&
                 (!owner_private || (opened.mode & 0o777) == 0o600)
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
      rescue JSON::ParserError
        raise Error, "workflow-creator evidence bundle entry is invalid JSON: #{name}"
      end

      def validate_installation!(document, kind:, candidate_sha:, artifact_manifest:)
        exact_hash!(
          document,
          %w[
            schema schema_version installation candidate_sha identity
            required_members inventory
          ],
          "installed manifest"
        )
        unless document["schema"] == INSTALLED_MANIFEST_SCHEMA &&
               document["schema_version"] == SCHEMA_VERSION &&
               document["installation"] == kind &&
               document["candidate_sha"] == candidate_sha
          raise Error, "workflow-creator installed-manifest identity is invalid"
        end
        inventory = validate_inventory!(document["inventory"])
        required_members = validate_required_members!(
          document["required_members"], inventory, kind: kind
        )
        closure_sha256 = installed_closure_sha256(
          required_members: required_members,
          inventory: inventory
        )
        if kind == "candidate"
          validate_candidate_identity!(
            document["identity"],
            artifact_manifest,
            required_members,
            closure_sha256
          )
        else
          validate_openclaw_identity!(
            document["identity"], required_members, closure_sha256,
            candidate_sha
          )
        end
      end

      def validate_candidate_identity!(identity, manifest, required_members,
                                       closure_sha256)
        exact_hash!(
          identity,
          %w[
            kind name version artifact_sha256 artifact_size closure_sha256
          ],
          "candidate installation identity"
        )
        gem_name, gem_record = manifest.fetch("files").find do |name, _record|
          name.match?(/\Ahive-cli-[0-9].*\.gem\z/)
        end
        package = required_members.fetch("package")
        valid =
          gem_name &&
          identity == {
            "kind" => "candidate_gem",
            "name" => "hive-cli",
            "version" => manifest["hive_version"],
            "artifact_sha256" => gem_record["sha256"],
            "artifact_size" => gem_record["size"],
            "closure_sha256" => closure_sha256
          } &&
          package.values_at("sha256", "size") ==
            gem_record.values_at("sha256", "size")
        raise Error, "workflow-creator candidate installation is not artifact-bound" unless valid
      end

      def validate_openclaw_identity!(identity, required_members,
                                      closure_sha256, candidate_sha)
        exact_hash!(
          identity,
          %w[
            kind name version integrity lock_sha256 lock_size package_sha256
            package_size closure_sha256 package_count provenance
          ],
          "OpenClaw installation identity"
        )
        package = required_members.fetch("package")
        lock = required_members.fetch("lock")
        valid =
          identity["kind"] == "openclaw_npm" &&
          identity["name"] == "openclaw" &&
          bounded_string?(identity["version"], 128) &&
          bounded_string?(identity["integrity"], 512) &&
          /\A[0-9a-f]{64}\z/.match?(identity["lock_sha256"].to_s) &&
          identity["lock_sha256"] == lock["sha256"] &&
          identity["lock_size"] == lock["size"] &&
          identity["package_sha256"] == package["sha256"] &&
          identity["package_size"] == package["size"] &&
          identity["closure_sha256"] == closure_sha256 &&
          identity["package_count"].is_a?(Integer) &&
          identity["package_count"].between?(1, 4096) &&
          identity.dig("provenance", "approval", "candidate_sha") ==
            candidate_sha
        raise Error, "workflow-creator OpenClaw installation identity is invalid" unless valid
      end

      def validate_inventory!(inventory)
        unless inventory.is_a?(Array) &&
               inventory.length.between?(1, MAX_INVENTORY_ENTRIES)
          raise Error, "workflow-creator installed inventory is invalid"
        end
        paths = inventory.map do |record|
          unless valid_inventory_record?(record)
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
        inventory
      end

      def validate_required_members!(required_members, inventory, kind:)
        expected_keys = kind == "candidate" ?
          CANDIDATE_REQUIRED_MEMBER_KEYS : REQUIRED_MEMBER_KEYS
        unless required_members.is_a?(Hash) &&
               required_members.keys.sort == expected_keys
          raise Error,
                "workflow-creator installed required members are invalid"
        end
        records = required_members.values
        unless records.all? { |record| valid_inventory_record?(record) } &&
               records.map { |record| record["path"] }.uniq.length ==
                 expected_keys.length &&
               records.all? { |record| inventory.include?(record) }
          raise Error,
                "workflow-creator installed required members are not bound to inventory"
        end
        required_members
      end

      def valid_inventory_record?(record)
        record.is_a?(Hash) &&
          record.keys.sort == FILE_RECORD_KEYS &&
          HiveLiveAgentProof.safe_relative_path?(record["path"]) &&
          /\A[0-9a-f]{64}\z/.match?(record["sha256"].to_s) &&
          record["size"].is_a?(Integer) &&
          record["size"].between?(0, MAX_INSTALLED_FILE_BYTES)
      end

      def validate_execution_receipt!(receipt, row:, candidate_sha:,
                                      candidate_installation:,
                                      openclaw_installation:)
        WorkflowCreatorExecutionContract.validate!(
          receipt: receipt,
          row: row,
          candidate_sha: candidate_sha,
          candidate_installation: candidate_installation,
          openclaw_installation: openclaw_installation
        )
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
