# frozen_string_literal: true

require_relative "proof_primitives"

module HiveLiveAgentProof
  class WorkflowCreatorBundle
    Snapshot = Struct.new(:row, :bytes, keyword_init: true)
    PRIMARY_NAME = WORKFLOW_CREATOR_BUNDLE_FILES.first
    SUPPORT = [
      [ "candidate_installation", "candidate-installed-manifest.json", "candidate" ],
      [ "openclaw_installation", "openclaw-installed-manifest.json", "openclaw" ],
      [ "execution_receipt", "execution-receipt.json", nil ]
    ].each(&:freeze).freeze
    INSTALLED_KEYS = %w[
      schema schema_version candidate_sha kind version closure_sha256
      required_roles inventory total_size secret_scan
    ].freeze
    MEMBER_KEYS = %w[path sha256 size].freeze
    MAX_DIRECTORY_ENTRIES = 16
    MAX_FILE_BYTES = 1_048_576
    MAX_INVENTORY_ENTRIES = 512
    MAX_MEMBER_BYTES = 268_435_456
    MAX_TOTAL_BYTES = 1_073_741_824
    SAFE_READ_FLAGS = if defined?(File::NONBLOCK) && defined?(File::NOFOLLOW)
      File::RDONLY | File::NONBLOCK | File::NOFOLLOW
    end

    class << self
      def validate!(mode:, directory:, manifest:, candidate_sha:, expected_row: nil)
        assert!(%i[source retained].include?(mode), "bundle mode is invalid")
        owner_private = mode == :source
        assert!(owner_private || expected_row.is_a?(Hash), "attested evidence is missing")
        root = File.expand_path(directory)
        root_stat = File.lstat(root)
        assert!(
          root_stat.directory? && !File.symlink?(root) && root_stat.uid == Process.uid &&
            (!owner_private || (root_stat.mode & 0o077).zero?),
          "bundle root is not an owner-private directory"
        )
        children = Dir.each_child(root).take(MAX_DIRECTORY_ENTRIES + 1)
        assert!(children.length <= MAX_DIRECTORY_ENTRIES, "bundle inventory exceeds the limit")
        inventory_valid = if owner_private
          children.sort == WORKFLOW_CREATOR_BUNDLE_FILES.sort
        else
          (WORKFLOW_CREATOR_BUNDLE_FILES - children).empty?
        end
        assert!(inventory_valid, "bundle inventory is invalid")
        bytes = WORKFLOW_CREATOR_BUNDLE_FILES.to_h do |name|
          [ name, read_file!(File.join(root, name), owner_private) ]
        end
        current_root = File.lstat(root)
        assert!(
          [ current_root.dev, current_root.ino ] == [ root_stat.dev, root_stat.ino ],
          "bundle root identity changed during validation"
        )
        documents = bytes.to_h { |name, content| [ name, JSON.parse(content) ] }
        documents.each do |name, document|
          assert!(bytes[name] == HiveLiveAgentProof.canonical_json(document),
                  "#{name} is not canonical JSON")
        end
        row = documents.fetch(PRIMARY_NAME)
        assert!(owner_private || row == expected_row,
                "retained primary does not match attestation")
        records = SUPPORT.map do |kind, name, _installation_kind|
          content = bytes.fetch(name)
          { "kind" => kind, "path" => name,
            "sha256" => Digest::SHA256.hexdigest(content), "size" => content.bytesize }
        end
        candidate = validate_installation!(
          documents.fetch(SUPPORT[0][1]), "candidate", manifest, candidate_sha
        )
        openclaw = validate_installation!(
          documents.fetch(SUPPORT[1][1]), "openclaw", manifest, candidate_sha
        )
        WorkflowCreatorContract.validate!(
          row: row, manifest: manifest, candidate_sha: candidate_sha,
          bundle_records: records
        )
        WorkflowCreatorExecutionContract.validate!(
          receipt: documents.fetch(SUPPORT[2][1]), row: row,
          candidate_sha: candidate_sha, installation_records: records.first(2),
          receipt_sha256: records.fetch(2).fetch("sha256"),
          candidate_installation: candidate, openclaw_installation: openclaw
        )
        frozen_row = JSON.parse(bytes.fetch(PRIMARY_NAME), freeze: true)
        Snapshot.new(
          row: frozen_row,
          bytes: bytes.transform_values { |content| content.b.freeze }.freeze
        ).freeze
      rescue JSON::ParserError
        raise Error, "workflow-creator bundle JSON is invalid"
      rescue SystemCallError, IOError
        raise Error, "workflow-creator bundle cannot be read safely"
      rescue KeyError, TypeError, NoMethodError, ArgumentError, JSON::GeneratorError
        raise Error, "workflow-creator bundle contract is invalid"
      end

      private

      def read_file!(path, owner_private)
        assert!(SAFE_READ_FLAGS, "safe file-open flags are unavailable")
        File.open(path, SAFE_READ_FLAGS) do |file|
          stat = file.stat
          assert!(
            stat.file? && stat.nlink == 1 && stat.uid == Process.uid &&
              stat.size <= MAX_FILE_BYTES &&
              (!owner_private || (stat.mode & 0o077).zero?),
            "bundle member is not a private regular file"
          )
          content = file.read(MAX_FILE_BYTES + 1)
          assert!(content.bytesize <= MAX_FILE_BYTES, "bundle member exceeds the size limit")
          current = file.stat
          assert!(
            [ current.dev, current.ino, current.size ] == [ stat.dev, stat.ino, stat.size ],
            "bundle member identity changed during validation"
          )
          content
        end
      end

      def validate_installation!(document, kind, manifest, candidate_sha)
        exact!(document, INSTALLED_KEYS, "installed manifest")
        exact!(document["secret_scan"], %w[scanner status], "installed manifest secret scan")
        inventory = document["inventory"]
        assert!(
          inventory.is_a?(Array) && inventory.length.between?(1, MAX_INVENTORY_ENTRIES) &&
            inventory.all? { |record| valid_file_record?(record) },
          "#{kind} installed inventory is invalid"
        )
        paths = inventory.map { |record| record["path"] }
        assert!(paths == paths.sort && paths.uniq.length == paths.length,
                "#{kind} installed inventory order is invalid")
        roles = WORKFLOW_CREATOR_MEMBER_ROLES.fetch(kind)
        required = document["required_roles"]
        exact!(required, roles, "#{kind} installed required roles")
        assert!(
          required.values.all? { |record| valid_file_record?(record) && inventory.include?(record) } &&
            required.values.map { |record| record["path"] }.uniq.length == roles.length,
          "#{kind} installed required roles are not inventory-bound"
        )
        closure = { "required_roles" => required, "inventory" => inventory }
        total = inventory.sum { |record| record["size"] }
        version_valid = kind == "candidate" ?
          document["version"] == manifest["hive_version"] :
          document["version"].is_a?(String) && !document["version"].empty?
        valid =
          document["schema"] == WORKFLOW_CREATOR_INSTALLED_SCHEMA &&
          document["schema_version"].is_a?(Integer) &&
          document["schema_version"] == SCHEMA_VERSION &&
          document["candidate_sha"] == candidate_sha && document["kind"] == kind &&
          version_valid &&
          document["closure_sha256"] == Digest::SHA256.hexdigest(
            HiveLiveAgentProof.canonical_json(closure)
          ) && document["total_size"].is_a?(Integer) &&
          document["total_size"] == total && total.between?(1, MAX_TOTAL_BYTES) &&
          document["secret_scan"] == { "status" => "passed", "scanner" => WORKFLOW_CREATOR_SCANNER }
        assert!(valid, "#{kind} installed manifest identity is invalid")
        if kind == "candidate"
          _name, artifact = manifest.fetch("files").find do |name, _record|
            name.match?(/\Ahive-cli-[0-9].*\.gem\z/)
          end
          package = required.fetch("package")
          assert!(artifact && package.slice("sha256", "size") == artifact.slice("sha256", "size"),
                  "candidate installed package does not match the release artifact")
        end
        findings = HiveLiveAgentProof.secret_findings(JSON.generate(document))
        assert!(findings.empty?, "installed manifest contains secret-shaped material")
        document
      end

      def valid_file_record?(record)
        record.is_a?(Hash) && record.keys.sort == MEMBER_KEYS &&
          HiveLiveAgentProof.safe_relative_path?(record["path"]) &&
          record["sha256"].is_a?(String) && SAFE_DIGEST.match?(record["sha256"]) &&
          record["size"].is_a?(Integer) && record["size"].between?(0, MAX_MEMBER_BYTES)
      end

      def exact!(value, keys, label)
        assert!(value.is_a?(Hash) && value.keys.sort == keys.sort, "#{label} fields are invalid")
      end

      def assert!(condition, message)
        raise Error, "workflow-creator #{message}" unless condition
      end
    end
  end
end
