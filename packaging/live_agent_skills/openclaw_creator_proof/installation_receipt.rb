module HiveLiveAgentProof
  module OpenClawCreatorProof
    class InstallationReceipt
      SCHEMA = InstallationIdentity::SCHEMA
      SCHEMA_VERSION = InstallationIdentity::SCHEMA_VERSION
      TREE_SCHEMA = InstallationIdentity::TREE_SCHEMA
      TREE_SCHEMA_VERSION = InstallationIdentity::TREE_SCHEMA_VERSION
      KINDS = InstallationIdentity::KINDS
      TREE_ENTRY_LIMIT = InstallationIdentity::TREE_ENTRY_LIMIT
      TREE_DIRECTORY_LIMIT = InstallationIdentity::TREE_DIRECTORY_LIMIT
      TREE_DEPTH_LIMIT = InstallationIdentity::TREE_DEPTH_LIMIT
      TREE_BYTE_LIMIT = InstallationIdentity::TREE_BYTE_LIMIT

      def self.write(path:, kind:, artifact_path:, install_root:, executable_path:,
                     package_name:, package_version:, package_integrity: nil,
                     lock_path: nil, package_count: nil,
                     interpreter_path: RbConfig.ruby)
        root = InstallationIdentity.canonical_directory!(
          install_root, "installation root"
        )
        executable = File.realpath(executable_path)
        artifact = File.realpath(artifact_path)
        lock = lock_path && File.realpath(lock_path)
        receipt_path = File.expand_path(path)
        manifest_path = "#{receipt_path}.tree.json"
        if InstallationIdentity.underneath?(receipt_path, root) ||
           InstallationIdentity.underneath?(manifest_path, root)
          raise Error,
                "installation receipt and tree manifest must be outside the installed tree"
        end

        InstallationIdentity.make_tree_read_only!(root)
        manifest = InstallationIdentity.build_tree_manifest(root)
        HiveLiveAgentProof.write_json(manifest_path, manifest)
        payload = {
          "schema" => SCHEMA,
          "schema_version" => SCHEMA_VERSION,
          "kind" => kind,
          "artifact" => InstallationIdentity.file_record(artifact),
          "install_root" => root,
          "tree_manifest" =>
            InstallationIdentity.file_record(File.realpath(manifest_path)),
          "interpreter" => InstallationIdentity.interpreter_record(interpreter_path),
          "launcher_interpreter" =>
            InstallationIdentity.launcher_interpreter_record(executable),
          "executable" => {
            "configured_path" => File.expand_path(executable_path),
            "realpath" => executable,
            "sha256" => Digest::SHA256.file(executable).hexdigest
          },
          "package" => {
            "name" => package_name,
            "version" => package_version
          },
          "lock" => nil
        }
        payload.fetch("package")["integrity"] = package_integrity if package_integrity
        if lock
          payload["lock"] = {
            "path" => lock,
            "sha256" => Digest::SHA256.file(lock).hexdigest,
            "package_count" => Integer(package_count)
          }
        end
        HiveLiveAgentProof.write_json(receipt_path, payload)
        payload
      rescue InstallationIdentity::Invalid, ArgumentError, TypeError,
             Timeout::Error => e
        raise Error, "cannot write installation receipt: #{e.message}"
      end

      def initialize(path:, expected_kind:, expected_package_name:,
                     expected_package_version:, expected_package_integrity: nil,
                     expected_lock_sha256: nil, expected_package_count: nil)
        @path = path.to_s
        @expected = {
          kind: expected_kind,
          package_name: expected_package_name,
          package_version: expected_package_version,
          package_integrity: expected_package_integrity,
          lock_sha256: expected_lock_sha256,
          package_count: expected_package_count
        }
      end

      def call
        InstallationIdentity.from_receipt!(path: @path, expected: @expected)
      rescue InstallationIdentity::Invalid => e
        raise Error, e.message
      end
    end
  end
end
