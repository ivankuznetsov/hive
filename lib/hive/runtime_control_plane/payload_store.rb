require "digest"
require "fileutils"
require "securerandom"
require "hive/atomic_file"
require "hive/runtime_control_plane"

module Hive
  module RuntimeControlPlane
    # Custody for retained logs and large outputs. Writers use stable open
    # paths; only terminal publication creates immutable content addresses.
    class PayloadStore
      MAX_PAYLOAD_BYTES = 256 * 1024 * 1024
      COMPONENT = /\A[A-Za-z0-9][A-Za-z0-9._-]{0,254}\z/

      class Error < RuntimeControlPlane::Error; end
      class PathError < Error; end
      class IntegrityError < Error; end

      attr_reader :root

      def initialize(root:, max_bytes: MAX_PAYLOAD_BYTES, after_copy: nil)
        @root = File.expand_path(root)
        @max_bytes = Integer(max_bytes)
        @after_copy = after_copy
        prepare_directory!(root)
        prepare_directory!(open_root)
        prepare_directory!(sealed_root)
        prepare_directory!(temporary_root)
      end

      def write_open(attempt_id:, name:, bytes:)
        attempt = component!(attempt_id, "attempt id")
        basename = component!(name, "payload name")
        directory = File.join(open_root, attempt)
        prepare_directory!(directory)
        path = File.join(directory, basename)
        reject_existing_unsafe!(path)
        Hive::AtomicFile.write(path, String(bytes), mode: 0o600)
        secure_file!(path)
        Hive::AtomicFile.fsync_directory(directory)
        path
      rescue SystemCallError, IOError => error
        raise_path_error!("cannot write open payload: #{error.message}", :payload_write_failed, path)
      end

      def seal(source_path, expected_sha256: nil, expected_size: nil)
        source = File.expand_path(source_path)
        before_path = secure_file!(source)
        temporary = File.join(temporary_root, "seal-#{Process.pid}-#{SecureRandom.hex(8)}")
        digest = Digest::SHA256.new
        size = 0
        flags = File::RDONLY
        flags |= File::NOFOLLOW if File.const_defined?(:NOFOLLOW)
        File.open(source, flags) do |input|
          before = input.stat
          same_inode!(before, before_path, source)
          File.open(temporary, File::WRONLY | File::CREAT | File::EXCL, 0o600) do |output|
            while (chunk = input.read(64 * 1024))
              size += chunk.bytesize
              integrity!("payload exceeds #{@max_bytes} bytes", :payload_too_large) if size > @max_bytes
              digest.update(chunk)
              output.write(chunk)
            end
            output.flush
            output.fsync
          end
          @after_copy&.call
          after = input.stat
          after_path = File.lstat(source)
          unless same_snapshot?(before, after) && same_snapshot?(before, after_path)
            integrity!("payload source changed while it was copied", :source_changed)
          end
        end

        sha256 = digest.hexdigest
        integrity!("payload digest differs from its expected digest", :source_digest_mismatch) if
          expected_sha256 && expected_sha256.to_s != sha256
        integrity!("payload size differs from its expected size", :source_size_mismatch) if
          expected_size && Integer(expected_size) != size

        destination = sealed_path(sha256)
        prepare_directory!(File.dirname(destination))
        if optional_lstat(destination)
          verify_file!(destination, sha256: sha256, size: size)
        else
          begin
            File.link(temporary, destination)
            File.unlink(temporary)
            temporary = nil
          rescue Errno::EEXIST
            verify_file!(destination, sha256: sha256, size: size)
          end
          File.chmod(0o600, destination)
          Hive::AtomicFile.fsync_directory(File.dirname(destination))
        end
        reference(sha256, size)
      rescue Error
        raise
      rescue Errno::ELOOP, Errno::EMLINK => error
        raise_path_error!("unsafe payload source: #{error.message}", :unsafe_payload_path, source)
      rescue SystemCallError, IOError, ArgumentError => error
        integrity!("payload sealing failed: #{error.message}", :payload_seal_failed)
      ensure
        FileUtils.rm_f(temporary) if temporary
      end

      def read_sealed(reference)
        sha256, size = validate_reference!(reference)
        path = path_for(reference)
        verified_bytes(path, sha256: sha256, size: size)
      rescue Errno::ENOENT
        integrity!("sealed payload is missing", :payload_missing)
      end

      def path_for(reference)
        sha256, = validate_reference!(reference)
        expected = sealed_path(sha256)
        supplied = reference["path"] || reference[:path]
        if supplied && supplied != relative_sealed_path(sha256)
          raise_path_error!("sealed payload reference path is not canonical", :payload_path_mismatch, supplied)
        end
        expected
      end

      # Callers supply only attempt identities already proven conclusively
      # lost. Merely absent from a current scan is not enough authority.
      def reclaim_open!(lost_attempt_ids:)
        Array(lost_attempt_ids).map { |id| component!(id, "attempt id") }.uniq.sort.flat_map do |attempt|
          directory = File.join(open_root, attempt)
          status = optional_lstat(directory)
          next [] unless status
          path_error!(directory, :unsafe_open_root) if status.symlink? || !status.directory?

          files = Dir.children(directory).sort.map do |name|
            component!(name, "payload name")
            path = File.join(directory, name)
            secure_file!(path)
            File.unlink(path)
            path
          end
          Dir.rmdir(directory)
          Hive::AtomicFile.fsync_directory(open_root)
          files
        end
      end

      private

      def reference(sha256, size)
        {
          "algorithm" => "sha256",
          "sha256" => sha256,
          "size" => size,
          "path" => relative_sealed_path(sha256)
        }.freeze
      end

      def validate_reference!(reference)
        unless reference.is_a?(Hash)
          integrity!("sealed payload reference must be an object", :payload_reference_invalid)
        end
        algorithm = reference["algorithm"] || reference[:algorithm]
        sha256 = reference["sha256"] || reference[:sha256]
        size = reference["size"] || reference[:size]
        unless algorithm == "sha256" && sha256.to_s.match?(/\A[0-9a-f]{64}\z/) &&
               Integer(size).between?(0, @max_bytes)
          integrity!("sealed payload reference is invalid", :payload_reference_invalid)
        end
        [ sha256.to_s, Integer(size) ]
      rescue ArgumentError, TypeError
        integrity!("sealed payload reference is invalid", :payload_reference_invalid)
      end

      def verify_file!(path, sha256:, size:)
        verified_bytes(path, sha256: sha256, size: size)
        true
      end

      def verified_bytes(path, sha256:, size:)
        path_status = secure_file!(path)
        integrity!("sealed payload size does not match its reference", :payload_size_mismatch) unless
          path_status.size == size
        flags = File::RDONLY
        flags |= File::NOFOLLOW if File.const_defined?(:NOFOLLOW)
        File.open(path, flags) do |file|
          before = file.stat
          same_inode!(before, path_status, path)
          bytes = file.read(size + 1)
          after = file.stat
          after_path = File.lstat(path)
          unless same_snapshot?(before, after) && same_snapshot?(before, after_path)
            integrity!("sealed payload changed while it was read", :payload_changed)
          end
          integrity!("sealed payload size does not match its reference", :payload_size_mismatch) unless
            bytes.bytesize == size
          integrity!("sealed payload digest does not match its reference", :payload_digest_mismatch) unless
            Digest::SHA256.hexdigest(bytes) == sha256
          bytes
        end
      rescue Errno::ENOENT
        integrity!("sealed payload is missing", :payload_missing)
      end

      def secure_file!(path)
        status = File.lstat(path)
        path_error!(path, :unsafe_payload_path) if status.symlink? || !status.file?
        path_error!(path, :payload_hardlink) unless status.nlink == 1
        path_error!(path, :payload_wrong_owner) unless status.uid == Process.euid
        status
      end

      def reject_existing_unsafe!(path)
        status = optional_lstat(path)
        secure_file!(path) if status
      end

      def prepare_directory!(path)
        status = optional_lstat(path)
        if status
          path_error!(path, :unsafe_payload_path) if status.symlink? || !status.directory?
          path_error!(path, :payload_wrong_owner) unless status.uid == Process.euid
        else
          FileUtils.mkdir_p(path, mode: 0o700)
        end
        File.chmod(0o700, path)
        path
      end

      def component!(value, label)
        component = value.to_s
        unless COMPONENT.match?(component) && component != "." && component != ".."
          raise_path_error!("#{label} is not a safe path component", :path_traversal, component)
        end
        component
      end

      def same_inode!(opened, path_status, path)
        return if opened.dev == path_status.dev && opened.ino == path_status.ino

        raise_path_error!("payload source changed before it was opened", :source_changed, path)
      end

      def same_snapshot?(left, right)
        [ left.dev, left.ino, left.size, left.mtime, left.ctime ] ==
          [ right.dev, right.ino, right.size, right.mtime, right.ctime ]
      end

      def sealed_path(sha256)
        File.join(sealed_root, "sha256", sha256[0, 2], sha256)
      end

      def relative_sealed_path(sha256)
        File.join("sealed", "sha256", sha256[0, 2], sha256)
      end

      def open_root = File.join(root, "open")
      def sealed_root = File.join(root, "sealed")
      def temporary_root = File.join(root, ".tmp")

      def optional_lstat(path)
        File.lstat(path)
      rescue Errno::ENOENT
        nil
      end

      def path_error!(path, code)
        raise_path_error!("unsafe payload path #{path}", code, path)
      end

      def raise_path_error!(message, code, path)
        raise PathError.new(message, code: code, details: { path: path })
      end

      def integrity!(message, code)
        raise IntegrityError.new(message, code: code)
      end
    end
  end
end
