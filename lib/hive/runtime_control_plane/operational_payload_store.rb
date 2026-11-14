require "digest"
require "fileutils"
require "hive/atomic_file"
require "hive/runtime_control_plane"

module Hive
  module RuntimeControlPlane
    # Content-addressed files that hold the daemon's derived `hive-status`
    # payload body. They live beside the runtime database but outside SQLite,
    # so writing a multi-MB payload never extends the shared write lock.
    #
    # The files are a cache, not a source of truth: writes skip fsync, and a
    # reader accepts bytes only when their size and SHA-256 match the
    # reference committed in the `daemon_runtime` row. A missing, torn, or
    # substituted file reads as unavailable, never as a different payload.
    class OperationalPayloadStore
      DIGEST = /\A[0-9a-f]{64}\z/
      PAYLOAD_FILE = /\A([0-9a-f]{64})\.json\z/
      TEMPORARY_FILE = /\A\.[0-9a-f]{64}\.json\.tmp\./
      STALE_TEMPORARY_SEC = 600

      attr_reader :root

      def initialize(root:, clock: -> { Time.now })
        @root = File.expand_path(root)
        @clock = clock
        @written = {}
      end

      # Returns true when bytes were written, false when this process already
      # wrote the same content address and the file has not changed since.
      # An unchanged payload therefore costs no file I/O on later ticks.
      def write(digest, bytes)
        path = path_for(digest)
        known = @written[digest]
        return false if known && known == signature(path)

        prepare_root!
        Hive::AtomicFile.write(path, bytes, mode: 0o600, fsync: false)
        @written[digest] = signature(path)
        true
      end

      def read(digest, expected_bytes)
        unless expected_bytes.is_a?(Integer) && expected_bytes >= 0
          raise_mismatch!("operational status payload reference has an invalid size")
        end

        flags = File::RDONLY | File::NONBLOCK
        flags |= File::NOFOLLOW if File.const_defined?(:NOFOLLOW)
        File.open(path_for(digest), flags) do |file|
          stat = file.stat
          unless stat.file? && stat.size == expected_bytes
            raise_mismatch!("operational status payload size differs from its reference")
          end

          bytes = file.read(expected_bytes + 1).to_s
          unless bytes.bytesize == expected_bytes && Digest::SHA256.hexdigest(bytes) == digest
            raise_mismatch!("operational status payload digest differs from its reference")
          end

          bytes.force_encoding(Encoding::UTF_8)
        end
      rescue SystemCallError, IOError => error
        raise IntegrityError.new(
          "operational status payload is unavailable: #{error.class}",
          code: :projection_payload_unavailable, details: { error_class: error.class.name }
        )
      end

      # Removes payload files outside `keep` and abandoned temporaries. Best
      # effort: a leftover file is harmless and the next prune retries it.
      def prune(keep:)
        retained = Array(keep)
        Dir.each_child(@root) do |name|
          path = File.join(@root, name)
          if (match = PAYLOAD_FILE.match(name))
            next if retained.include?(match[1])

            @written.delete(match[1])
            File.unlink(path)
          elsif TEMPORARY_FILE.match?(name) &&
                @clock.call - File.lstat(path).mtime > STALE_TEMPORARY_SEC
            File.unlink(path)
          end
        rescue SystemCallError
          next
        end
        true
      rescue SystemCallError
        false
      end

      private

      def path_for(digest)
        raise_mismatch!("operational status payload digest is invalid") unless
          digest.is_a?(String) && DIGEST.match?(digest)

        File.join(@root, "#{digest}.json")
      end

      def prepare_root!
        FileUtils.mkdir_p(@root, mode: 0o700)
        raise Errno::ENOTDIR, @root unless File.lstat(@root).directory?
      end

      def signature(path)
        stat = File.lstat(path)
        return nil unless stat.file?

        [ stat.dev, stat.ino, stat.size, stat.mtime.to_r, stat.ctime.to_r ]
      rescue SystemCallError
        nil
      end

      def raise_mismatch!(message)
        raise IntegrityError.new(message, code: :projection_payload_mismatch)
      end
    end
  end
end
