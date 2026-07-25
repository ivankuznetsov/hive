require "digest"
require "fileutils"
require "find"
require "json"
require "securerandom"
require "hive/atomic_file"
require "hive/paths"
require "hive/workflow_package/canonical_json"
require "hive/workflow_package/publish_lock"
require "hive/workflow_package/publish_receipt"
require "hive/workflow_package/safe_file"
require "hive/workflow_package/validator"

module Hive
  module WorkflowPackage
    class PublishStore
      MAX_RECEIPT_BYTES = 128 * 1024

      attr_reader :root

      def initialize(root: Hive::Paths.workflow_publish_root)
        @root = File.expand_path(root)
        ensure_layout!
      end

      def create_or_load(package, registry:)
        key = identity_key(registry, package.name, package.version)
        with_identity_lock(registry, package.name, package.version) do
          path = receipt_path(registry, package.name, package.version)
          if File.exist?(path) || File.symlink?(path)
            receipt = read_receipt(path)
            receipt.assert_identity!(
              registry: registry, name: package.name, version: package.version,
              package_digest: package.package_digest, release_digest: package.release_digest,
              lint_contract: package.lint_contract
            )
            verify_bundle(receipt)
            next receipt
          end

          persist_bundle(package)
          receipt = PublishReceipt.build(
            registry: registry, name: package.name, version: package.version,
            package_digest: package.package_digest, release_digest: package.release_digest,
            lint_contract: package.lint_contract
          )
          write_receipt(path, receipt)
          receipt
        end
      end

      def load(registry, name, version)
        path = receipt_path(registry, name, version)
        return nil unless File.exist?(path) || File.symlink?(path)
        read_receipt(path)
      end

      def save(receipt)
        path = receipt_path(receipt.registry, receipt.name, receipt.version)
        with_identity_lock(receipt.registry, receipt.name, receipt.version) do
          current = read_receipt(path)
          current.assert_continuation!(receipt)
          write_receipt(path, receipt)
        end
        receipt
      end

      def update(registry, name, version)
        path = receipt_path(registry, name, version)
        with_identity_lock(registry, name, version) do
          current = read_receipt(path)
          updated = yield current
          raise PublishRecoveryError, "publication receipt update returned an invalid value" unless updated.is_a?(PublishReceipt)
          current.assert_continuation!(updated)
          write_receipt(path, updated)
          updated
        end
      end

      def receipt_path(registry, name, version)
        File.join(receipts_root, "#{identity_key(registry, name, version)}.json")
      end

      def with_identity_lock(registry, name, version)
        key = identity_key(registry, name, version)
        held = (Thread.current[:hive_publish_store_locks] ||= {})
        token = [ object_id, key ]
        return yield if held[token]

        PublishLock.with_lock(root, key) do
          held[token] = true
          yield
        ensure
          held.delete(token)
        end
      end

      def bundle_path(package_digest)
        raise PublishRecoveryError, "bundle digest is malformed" unless PublishReceipt::SHA256.match?(package_digest.to_s)
        File.join(bundles_root, package_digest)
      end

      def verify_bundle(receipt)
        path = bundle_path(receipt.package_digest)
        secure_directory!(path)
        manifest_path = File.join(path, "manifest.yml")
        manifest_bytes, = read_secure_file(
          manifest_path, max_bytes: MAX_RECEIPT_BYTES,
          message: "retained manifest is oversized, linked, or unreadable"
        )
        package_digest = ::Digest::SHA256.hexdigest(manifest_bytes)
        unless secure_equal?(package_digest, receipt.package_digest)
          raise PublishRecoveryError, "retained bundle manifest digest does not match its receipt"
        end
        manifest = RegistryManifest.load_bytes(manifest_bytes)
        unless manifest.data.fetch("version") == receipt.version &&
               manifest.data.fetch("name") == receipt.name &&
               manifest.data.fetch("release_sha256") == receipt.release_digest
          raise PublishRecoveryError, "retained bundle manifest identity does not match its receipt"
        end
        result = Validator.validate!(
          path, expected_name: receipt.name,
          expected_manifest_digest: receipt.release_digest
        )
        unless result.manifest.data.fetch("version") == receipt.version
          raise PublishRecoveryError, "retained bundle version does not match its receipt"
        end
        path
      rescue PackageError, Hive::ConfigError => e
        raise e if e.is_a?(PublishRecoveryError)
        raise PublishRecoveryError, "retained publication bundle failed validation"
      end

      def mark_bundle_gc_eligible(receipt)
        path = File.join(gc_eligible_root, "#{receipt.package_digest}.json")
        bytes = CanonicalJSON.generate(
          "schema" => "hive.workflow-publish-gc/v1",
          "package_digest" => receipt.package_digest,
          "registry" => receipt.registry,
          "name" => receipt.name,
          "version" => receipt.version
        )
        Hive::AtomicFile.write(path, bytes, mode: 0o600)
        File.chmod(0o600, path)
        Hive::AtomicFile.fsync_directory(gc_eligible_root)
        path
      rescue SystemCallError, IOError
        raise PublishRecoveryError, "publication bundle could not be marked GC-eligible"
      end

      def bundle_gc_eligible?(package_digest)
        path = File.join(gc_eligible_root, "#{package_digest}.json")
        File.file?(path) && !File.symlink?(path)
      end

      private

      def ensure_layout!
        PublishLock.ensure_private_directory!(root)
        PublishLock.ensure_private_directory!(receipts_root)
        PublishLock.ensure_private_directory!(bundles_root)
        PublishLock.ensure_private_directory!(gc_eligible_root)
        PublishLock.ensure_private_directory!(File.join(root, "locks"))
      end

      def receipts_root = File.join(root, "receipts")
      def bundles_root = File.join(root, "bundles")
      def gc_eligible_root = File.join(root, "gc-eligible")

      def identity_key(registry, name, version)
        ::Digest::SHA256.hexdigest([ registry, name, version ].join("\0"))
      end

      def persist_bundle(package)
        source_manifest = File.join(package.root, "manifest.yml")
        source_bytes = SafeFile.read(
          source_manifest, max_bytes: MAX_RECEIPT_BYTES, error_class: PublishRecoveryError,
          message: "validated package manifest changed before retention"
        ).first
        source_digest = ::Digest::SHA256.hexdigest(source_bytes)
        unless secure_equal?(source_digest, package.package_digest)
          raise PublishRecoveryError, "validated package manifest changed before retention"
        end
        Validator.validate!(
          package.root, expected_name: package.name,
          expected_manifest_digest: package.release_digest
        )
        target = bundle_path(package.package_digest)
        PublishLock.with_lock(root, "bundle:#{package.package_digest}") do
          if File.exist?(target) || File.symlink?(target)
            receipt = PublishReceipt.build(
              registry: "local/bundle", name: package.name, version: package.version,
              package_digest: package.package_digest, release_digest: package.release_digest,
              lint_contract: package.lint_contract
            )
            verify_bundle(receipt)
            next target
          end

          stage = File.join(bundles_root, ".stage-#{Process.pid}-#{SecureRandom.hex(6)}")
          FileUtils.mkdir_p(stage, mode: 0o700)
          File.chmod(0o700, stage)
          copy_tree(package.root, stage)
          File.rename(stage, target)
          Hive::AtomicFile.fsync_directory(bundles_root)
          target
        ensure
          FileUtils.rm_rf(stage) if stage && File.exist?(stage)
        end
      rescue PackageError, Errno::ENOENT, Errno::EACCES, IOError => e
        raise e if e.is_a?(PublishRecoveryError)
        raise PublishRecoveryError, "validated package could not be retained safely"
      end

      def copy_tree(source, destination)
        Find.find(source) do |path|
          next if path == source
          relative = path.delete_prefix("#{source}/")
          stat = File.lstat(path)
          raise PublishRecoveryError, "validated package contains a linked or special file" if stat.symlink? || (!stat.directory? && !stat.file?)
          target = File.join(destination, relative)
          if stat.directory?
            FileUtils.mkdir_p(target, mode: 0o700)
            File.chmod(0o700, target)
          else
            bytes, current = SafeFile.read(
              path, max_bytes: Manifest::MAX_FILE_BYTES, error_class: PublishRecoveryError,
              message: "validated package contains an unreadable or changing file"
            )
            unless current.dev == stat.dev && current.ino == stat.ino
              raise PublishRecoveryError, "validated package changed while being retained"
            end
            mode = (current.mode & 0o111).positive? ? 0o700 : 0o600
            File.open(target, File::WRONLY | File::CREAT | File::EXCL, mode) { |file| file.binmode; file.write(bytes) }
            File.chmod(mode, target)
          end
        end
      end

      def write_receipt(path, receipt)
        bytes = CanonicalJSON.generate(receipt.to_h)
        raise PublishRecoveryError, "publication receipt exceeds its size limit" if bytes.bytesize > MAX_RECEIPT_BYTES
        Hive::AtomicFile.write(path, bytes, mode: 0o600)
        File.chmod(0o600, path)
        Hive::AtomicFile.fsync_directory(File.dirname(path))
      end

      def read_receipt(path)
        bytes, = read_secure_file(
          path, max_bytes: MAX_RECEIPT_BYTES, mode: 0o600,
          message: "publication receipt is oversized, linked, or not owner-private"
        )
        data = JSON.parse(bytes)
        unless bytes == CanonicalJSON.generate(data)
          raise PublishRecoveryError, "publication receipt is not canonical JSON"
        end
        PublishReceipt.from_h(data)
      rescue JSON::ParserError, EncodingError
        raise PublishRecoveryError, "publication receipt is malformed"
      end

      def secure_directory!(path)
        stat = File.lstat(path)
        unless stat.directory? && !stat.symlink? && stat.uid == Process.uid && (stat.mode & 0o077).zero?
          raise PublishRecoveryError, "publication bundle directory is not owner-private"
        end
        stat
      rescue Errno::ENOENT, Errno::EACCES, IOError
        raise PublishRecoveryError, "publication bundle is missing or unreadable"
      end

      def secure_file!(path)
        read_secure_file(
          path, max_bytes: Manifest::MAX_FILE_BYTES,
          message: "publication state file is linked, special, or not owned by the current user"
        ).last
      end

      def read_secure_file(path, max_bytes:, message:, mode: nil)
        SafeFile.read(
          path, max_bytes: max_bytes, error_class: PublishRecoveryError,
          message: message, mode: mode, owner_uid: Process.uid
        )
      end

      def symbol_identity(receipt)
        {
          registry: receipt.registry, name: receipt.name, version: receipt.version,
          package_digest: receipt.package_digest, release_digest: receipt.release_digest,
          lint_contract: receipt.lint_contract
        }
      end

      def secure_equal?(left, right)
        left.bytesize == right.bytesize &&
          left.bytes.zip(right.bytes).reduce(0) { |memo, (a, b)| memo | (a ^ b) }.zero?
      end
    end
  end
end
