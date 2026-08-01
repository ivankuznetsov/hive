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
      schema schema_version candidate_sha kind version closure_sha256 members
      total_size secret_scan
    ].freeze
    MEMBER_KEYS = %w[role path sha256 size].freeze
    MAX_FILE_BYTES = 1_048_576
    MAX_MEMBER_BYTES = 268_435_456
    MAX_TOTAL_BYTES = 1_073_741_824
    class << self
      def validate_source!(directory:, manifest:, candidate_sha:)
        validate!(directory, manifest, candidate_sha, nil, true)
      end

      def validate_retained!(directory:, expected_row:, manifest:, candidate_sha:)
        validate!(directory, manifest, candidate_sha, expected_row, false)
      end

      private

      def validate!(directory, manifest, candidate_sha, expected_row, owner_private)
        root = File.expand_path(directory)
        root_stat = File.lstat(root)
        assert!(
          root_stat.directory? && !File.symlink?(root) &&
            (!owner_private ||
             (root_stat.uid == Process.uid && (root_stat.mode & 0o077).zero?)),
          "bundle root is not an owner-private directory"
        )
        children = Dir.children(root)
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
          assert!(
            bytes[name] == HiveLiveAgentProof.canonical_json(document),
            "#{name} is not canonical JSON"
          )
        end
        row = documents.fetch(PRIMARY_NAME)
        assert!(
          expected_row.nil? || row == expected_row,
          "retained primary does not match attestation"
        )
        records = bundle_records(bytes)
        validate_installation!(documents.fetch(SUPPORT[0][1]), "candidate", manifest, candidate_sha)
        validate_installation!(documents.fetch(SUPPORT[1][1]), "openclaw", manifest, candidate_sha)
        WorkflowCreatorContract.validate!(
          row: row, manifest: manifest, candidate_sha: candidate_sha,
          bundle_records: records
        )
        WorkflowCreatorExecutionContract.validate!(
          receipt: documents.fetch(SUPPORT[2][1]), row: row,
          candidate_sha: candidate_sha, installation_records: records.first(2),
          receipt_sha256: records.fetch(2).fetch("sha256")
        )
        Snapshot.new(row: row, bytes: bytes.transform_values(&:freeze).freeze)
      rescue JSON::ParserError
        fail_contract!("bundle JSON is invalid")
      rescue Errno::ENOENT, Errno::EACCES, Errno::ELOOP, IOError
        fail_contract!("bundle cannot be read safely")
      rescue KeyError, TypeError, NoMethodError, ArgumentError, JSON::GeneratorError
        fail_contract!("bundle contract is invalid")
      end

      def read_file!(path, owner_private)
        flags = File::RDONLY
        flags |= File::NOFOLLOW if defined?(File::NOFOLLOW)
        File.open(path, flags) do |file|
          stat = file.stat
          assert!(
            stat.file? && stat.nlink == 1 && stat.size <= MAX_FILE_BYTES &&
              (!owner_private ||
               (stat.uid == Process.uid && (stat.mode & 0o077).zero?)),
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
        members = document["members"]
        roles = WORKFLOW_CREATOR_MEMBER_ROLES.fetch(kind)
        assert!(
          members.is_a?(Array) && members.map { |member| member["role"] } == roles,
          "#{kind} installed manifest roles are invalid"
        )
        members.each do |member|
          exact!(member, MEMBER_KEYS, "installed member")
          valid = HiveLiveAgentProof.safe_relative_path?(member["path"]) &&
            member["sha256"].is_a?(String) && SAFE_DIGEST.match?(member["sha256"]) &&
            member["size"].is_a?(Integer) &&
            member["size"].between?(1, MAX_MEMBER_BYTES)
          assert!(valid, "#{kind} installed member is invalid")
        end
        valid =
          document["schema"] == WORKFLOW_CREATOR_INSTALLED_SCHEMA &&
          document["schema_version"] == SCHEMA_VERSION &&
          document["candidate_sha"] == candidate_sha && document["kind"] == kind &&
          document["version"].is_a?(String) && !document["version"].empty? &&
          document["closure_sha256"] == Digest::SHA256.hexdigest(HiveLiveAgentProof.canonical_json(members)) &&
          document["total_size"] == members.sum { |member| member["size"] } &&
          document["total_size"].between?(1, MAX_TOTAL_BYTES) &&
          members.map { |member| member["path"] }.uniq.length == members.length &&
          document["secret_scan"] == { "status" => "passed", "scanner" => WORKFLOW_CREATOR_SCANNER }
        assert!(valid, "#{kind} installed manifest identity is invalid")
        if kind == "candidate"
          _name, artifact = manifest.fetch("files").find { |name, _record| name.match?(/\Ahive-cli-[0-9].*\.gem\z/) }
          package = members.fetch(roles.index("package"))
          assert!(
            artifact && package.slice("sha256", "size") == artifact.slice("sha256", "size"),
            "candidate installed package does not match the release artifact"
          )
        end
        findings = HiveLiveAgentProof.secret_findings(JSON.generate(document))
        assert!(findings.empty?, "installed manifest contains secret-shaped material")
        true
      end

      def bundle_records(bytes)
        SUPPORT.map do |kind, name, _installation_kind|
          { "kind" => kind, "path" => name,
            "sha256" => Digest::SHA256.hexdigest(bytes.fetch(name)),
            "size" => bytes.fetch(name).bytesize }
        end
      end

      def exact!(value, keys, label)
        assert!(value.is_a?(Hash) && value.keys.sort == keys.sort, "#{label} fields are invalid")
      end

      def assert!(condition, message)
        fail_contract!(message) unless condition
      end

      def fail_contract!(message)
        raise Error, "workflow-creator #{message}"
      end
    end
  end
end
