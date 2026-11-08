require "digest"
require "json"
require "fileutils"
require "time"
require "hive/atomic_file"
require "hive/lock"
require "hive/managed_directory"
require "hive/user_service/transaction_journal"
require "hive/user_service/applied_receipt"

module Hive
  class UserService
    class Transaction
      class Busy < StandardError; end
      class Unsafe < StandardError; end
      class OperationFailure < StandardError
        attr_reader :error

        def initialize(error)
          @error = error
          super(error.message)
        end
      end
      private_constant :OperationFailure

      LOCK_WAIT_SEC = 0.25
      LOCK_POLL_SEC = 0.025
      ROOT_RELATIVE = ".local/state/hive/user-service"
      BOOTSTRAP_LOCK_NAME = ".hive-user-service-bootstrap.lock"
      BOOT_ID_PATTERN = /\A[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}\z/
      HOLDER_KEYS = %w[pid boot_id process_start target_path acquired_at].freeze
      TARGET_MAX_BYTES = TransactionJournal::TARGET_MAX_BYTES

      attr_reader :root, :lock_path, :journal, :receipt

      def initialize(definition:, home:, clock: -> { Time.now.utc },
                     lock_wait: LOCK_WAIT_SEC)
        @definition = definition
        @home = canonical_home(home)
        validate_target_home!
        @canonical_target_path = canonical_target_path(@definition.target_path)
        @target_name = File.basename(@canonical_target_path)
        @target_directory = Hive::ManagedDirectory.new(
          root: File.dirname(@canonical_target_path),
          anchor: @home,
          label: "user-service target"
        )
        @clock = clock
        @lock_wait = Float(lock_wait)
        @root = File.join(@home, ROOT_RELATIVE)
        key = Digest::SHA256.hexdigest(@canonical_target_path)
        @lock_name = "#{key}.lock"
        @guard_name = "#{key}.guard"
        @lock_path = File.join(root, "#{key}.lock")
        @bootstrap_directory = Hive::ManagedDirectory.new(
          root: @home,
          anchor: @home,
          label: "user-service bootstrap"
        )
        @directory = Hive::ManagedDirectory.new(
          root: root,
          anchor: @home,
          label: "user-service coordination"
        )
        coordination_definition = Definition.new(
          platform: @definition.platform,
          service_name: @definition.service_name,
          target_path: @canonical_target_path,
          content: @definition.content,
          launchd_label: @definition.launchd_label
        )
        @journal = TransactionJournal.new(
          directory: @directory, name: "#{key}.journal.json",
          definition: coordination_definition, clock: clock
        )
        @receipt = AppliedReceipt.new(
          directory: @directory, name: "#{key}.receipt.json",
          definition: coordination_definition, clock: clock
        )
      end

      def with_lock
        ensure_root!
        with_target_guard { with_holder_lock { yield self } }
      rescue OperationFailure => failure
        raise failure.error
      end

      def clear_after_verified_removal
        journal.read
        receipt.read
        journal.delete
        receipt.delete
      end

      def publish_target(content, expected_snapshot:, expected_digest:,
                         expected_missing:)
        @target_directory.atomic_write(
          @target_name,
          content,
          mode: 0o644,
          expected_snapshot: expected_snapshot,
          expected_digest: expected_digest,
          expected_missing: expected_missing,
          max_existing_bytes: TARGET_MAX_BYTES
        )
      rescue Hive::ConfigError => error
        raise Unsafe, "unsafe user-service target publication: #{error.message}"
      end

      def unlink_target(expected_snapshot:, expected_digest:)
        @target_directory.unlink(
          @target_name,
          expected_snapshot: expected_snapshot,
          expected_digest: expected_digest,
          max_bytes: TARGET_MAX_BYTES
        )
      rescue Hive::ConfigError => error
        raise Unsafe, "unsafe user-service target removal: #{error.message}"
      end

      private

      def with_target_guard
        deadline = monotonic + @lock_wait
        loop do
          acquired = false
          result = @directory.with_lock(@guard_name, nonblock: true) do
            acquired = true
            yield
          end
          return result if acquired
          raise Busy, "user-service target is busy" if monotonic >= deadline

          sleep LOCK_POLL_SEC
        end
      rescue Hive::ConfigError => error
        raise Unsafe, "unsafe user-service target guard: #{error.message}"
      end

      def with_holder_lock
        flags = File::RDWR | File::CREAT
        flags |= File::NOFOLLOW if File.const_defined?(:NOFOLLOW)
        File.open(lock_path, flags, 0o600) do |lock|
          acquired = false
          owns_record = false
          validate_lock_binding!(lock)
          deadline = monotonic + @lock_wait
          until lock.flock(File::LOCK_EX | File::LOCK_NB)
            if monotonic >= deadline
              case holder_state(lock)
              when :live
                raise Busy, "user-service target is busy"
              when :stale
                raise Unsafe, "stale user-service holder remains kernel-locked"
              else
                raise Unsafe, "user-service lock holder identity cannot be proven"
              end
            end

            sleep LOCK_POLL_SEC
          end
          acquired = true
          validate_lock_binding!(lock)
          validate_reclaimable_holder!(lock) unless lock.size.zero?
          write_holder(lock)
          owns_record = true
          result = begin
            yield
          rescue StandardError => error
            raise OperationFailure.new(error)
          end
          validate_lock_binding!(lock)
          result
        ensure
          clear_holder(lock) if acquired && owns_record && lock_binding_valid?(lock)
          lock&.flock(File::LOCK_UN)
        end
      rescue OperationFailure
        raise
      rescue Errno::ENOENT, Errno::ELOOP, Errno::EACCES, Errno::EPERM => error
        raise Unsafe, "unsafe user-service lock: #{error.class}"
      end

      def canonical_home(home)
        expanded = File.expand_path(String(home))
        stat = File.lstat(expanded)
        raise Unsafe, "user-service home must not be a symlink" if stat.symlink?
        raise Unsafe, "user-service home must be a directory" unless stat.directory?
        raise Unsafe, "user-service home has a foreign owner" unless stat.uid == Process.euid
        raise Unsafe, "user-service home is writable by another user" unless (stat.mode & 0o022).zero?

        real = File.realpath(expanded)
        raise Unsafe, "user-service home is redirected" unless real == expanded

        real
      rescue Errno::ENOENT, Errno::EACCES, Errno::EPERM => error
        raise Unsafe, "user-service home is unavailable: #{error.class}"
      end

      def validate_target_home!
        target = File.expand_path(@definition.target_path)
        marker = [ "/.config/systemd/user/", "/Library/LaunchAgents/" ]
          .find { |candidate| target.include?(candidate) }
        expected = if marker
          target[0...target.index(marker)]
        else
          File.dirname(target)
        end
        expected = File.realpath(expected)
        unless expected == @home
          raise Unsafe, "user-service target is not anchored to its real home"
        end
      rescue Errno::ENOENT, Errno::EACCES, Errno::EPERM => error
        raise Unsafe, "user-service target home is unavailable: #{error.class}"
      end

      def canonical_target_path(path)
        expanded = File.expand_path(path)
        name = File.basename(expanded)
        cursor = File.dirname(expanded)
        suffix = []
        loop do
          begin
            base = File.realpath(cursor)
            return File.join(base, *suffix, name)
          rescue Errno::ENOENT
            parent = File.dirname(cursor)
            raise Unsafe, "user-service target has no existing ancestor" if parent == cursor

            suffix.unshift(File.basename(cursor))
            cursor = parent
          end
        end
      rescue Errno::EACCES, Errno::EPERM, Errno::ELOOP => error
        raise Unsafe, "user-service target cannot be canonicalized: #{error.class}"
      end

      def ensure_root!
        deadline = monotonic + @lock_wait
        loop do
          validate_existing_bootstrap_lock!
          acquired = @bootstrap_directory.with_lock(
            BOOTSTRAP_LOCK_NAME,
            nonblock: true
          ) do
            validate_bootstrap_lock!
            Hive::AtomicFile.fsync_directory(@home)
            @directory.prepare!
            validate_coordination_tree!
            ensure_coordination_lock_exists!(@lock_name)
            ensure_coordination_lock_exists!(@guard_name)
            true
          end
          return if acquired
          raise Busy, "user-service coordination bootstrap is busy" if monotonic >= deadline

          sleep LOCK_POLL_SEC
        end
      rescue Hive::ConfigError => error
        raise Unsafe, "unsafe user-service coordination bootstrap: #{error.message}"
      end

      def validate_existing_bootstrap_lock!
        snapshot = @bootstrap_directory.read_with_metadata(
          BOOTSTRAP_LOCK_NAME,
          max_bytes: 1,
          missing: true
        )
        return unless snapshot

        path = File.join(@home, BOOTSTRAP_LOCK_NAME)
        stat = File.lstat(path)
        unless snapshot.fetch(:bytes).empty? && snapshot.fetch(:mode) == 0o600 &&
               stat.uid == Process.euid
          raise Unsafe, "unsafe user-service bootstrap lock"
        end
      end

      def validate_bootstrap_lock!
        path = File.join(@home, BOOTSTRAP_LOCK_NAME)
        stat = File.lstat(path)
        unless stat.file? && !stat.symlink? && stat.uid == Process.euid &&
               (stat.mode & 0o777) == 0o600 && stat.nlink == 1
          raise Unsafe, "unsafe user-service bootstrap lock"
        end
      end

      def validate_coordination_tree!
        cursor = @home
        ROOT_RELATIVE.split("/").each do |component|
          cursor = File.join(cursor, component)
          validate_directory!(cursor, private: cursor == root)
        end
      end

      def ensure_coordination_lock_exists!(name)
        type = @directory.entry_type(name, missing: true)
        return if type == :regular

        created = @directory.with_lock(name, nonblock: true) { true }
        if created || @directory.entry_type(name, missing: true) == :regular
          Hive::AtomicFile.fsync_directory(root)
          return
        end

        raise Busy, "user-service target lock bootstrap is busy"
      end

      def validate_directory!(path, private: false)
        stat = File.lstat(path)
        safe = stat.directory? && !stat.symlink? && stat.uid == Process.euid &&
          (stat.mode & 0o022).zero?
        safe &&= (stat.mode & 0o077).zero? if private
        unless safe
          raise Unsafe, "unsafe user-service coordination directory"
        end
      rescue Errno::ENOENT, Errno::ELOOP, Errno::EACCES, Errno::EPERM => error
        raise Unsafe, "unavailable user-service coordination directory: #{error.class}"
      end

      def validate_lock!(lock)
        stat = lock.stat
        unless stat.file? && stat.uid == Process.euid && (stat.mode & 0o777) == 0o600 && stat.nlink == 1
          raise Unsafe, "unsafe user-service lock file"
        end
      end

      def validate_lock_binding!(lock)
        opened = lock.stat
        bound = File.lstat(lock_path)
        unless opened.dev == bound.dev && opened.ino == bound.ino &&
               opened.nlink == 1 && bound.nlink == 1
          raise Unsafe, "user-service lock binding changed"
        end
        validate_lock!(lock)
        unless bound.file? && !bound.symlink? && bound.uid == Process.euid &&
               (bound.mode & 0o777) == 0o600
          raise Unsafe, "unsafe user-service lock file"
        end
      end

      def lock_binding_valid?(lock)
        opened = lock.stat
        bound = File.lstat(lock_path)
        bound.file? && !bound.symlink? &&
          opened.dev == bound.dev && opened.ino == bound.ino &&
          opened.nlink == 1 && bound.nlink == 1 &&
          bound.uid == Process.euid && (bound.mode & 0o777) == 0o600
      rescue IOError, SystemCallError
        false
      end

      def write_holder(lock)
        holder = {
          "pid" => Process.pid,
          "boot_id" => boot_id,
          "process_start" => Hive::Lock.process_start_time(Process.pid) || "unavailable",
          "target_path" => @canonical_target_path,
          "acquired_at" => @clock.call.utc.iso8601(6)
        }
        lock.rewind
        lock.truncate(0)
        lock.write(JSON.generate(holder) + "\n")
        lock.flush
        lock.fsync
      end

      def clear_holder(lock)
        lock.rewind
        lock.truncate(0)
        lock.flush
        lock.fsync
      rescue IOError, SystemCallError
        nil
      end

      def validate_reclaimable_holder!(lock)
        state = holder_state(lock)
        return if state == :stale

        message = state == :live ?
          "live user-service holder record is not reclaimable" :
          "user-service holder record cannot be proven stale"
        raise Unsafe, message
      end

      def boot_id
        File.read("/proc/sys/kernel/random/boot_id").strip
      rescue Errno::ENOENT, Errno::EACCES
        "unavailable"
      end

      def holder_state(lock)
        holder = read_holder(lock)
        recorded_boot = holder.fetch("boot_id")
        current_boot = boot_id
        return :stale if recorded_boot != "unavailable" &&
                         current_boot != "unavailable" &&
                         recorded_boot != current_boot

        pid = holder.fetch("pid")
        begin
          Process.kill(0, pid)
        rescue Errno::ESRCH
          return :stale
        rescue Errno::EPERM
          return :unprovable
        end

        recorded_start = holder.fetch("process_start")
        current_start = Hive::Lock.process_start_time(pid)
        return :unprovable if recorded_boot == "unavailable" ||
                              current_boot == "unavailable" ||
                              recorded_start == "unavailable" ||
                              current_start.nil?
        return :stale unless recorded_start.to_s == current_start.to_s

        :live
      end

      def read_holder(lock)
        lock.rewind
        raw = lock.read(16 * 1024 + 1)
        raise Unsafe, "user-service lock holder record is oversized" if raw.bytesize > 16 * 1024

        holder = JSON.parse(raw)
        unless holder.is_a?(Hash) && holder.keys.sort == HOLDER_KEYS.sort &&
               holder["pid"].is_a?(Integer) && holder["pid"].positive? &&
               valid_boot_id?(holder["boot_id"]) &&
               holder["process_start"].is_a?(String) && !holder["process_start"].empty? &&
               holder["target_path"] == @canonical_target_path &&
               valid_time?(holder["acquired_at"])
          raise Unsafe, "invalid user-service lock holder record"
        end
        holder
      rescue JSON::ParserError, TypeError
        raise Unsafe, "invalid user-service lock holder record"
      end

      def valid_boot_id?(value)
        value == "unavailable" || (value.is_a?(String) && value.match?(BOOT_ID_PATTERN))
      end

      def valid_time?(value)
        return false unless value.is_a?(String)

        Time.iso8601(value)
        true
      rescue ArgumentError
        false
      end

      def monotonic
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end
    end
  end
end
