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

      LOCK_WAIT_SEC = 0.25
      LOCK_POLL_SEC = 0.025
      ROOT_RELATIVE = ".local/state/hive/user-service"
      HOLDER_KEYS = %w[pid boot_id process_start target_path acquired_at].freeze

      attr_reader :root, :lock_path, :journal, :receipt

      def initialize(definition:, home:, clock: -> { Time.now.utc },
                     lock_wait: LOCK_WAIT_SEC)
        @definition = definition
        @home = canonical_home(home)
        @clock = clock
        @lock_wait = Float(lock_wait)
        @root = File.join(@home, ROOT_RELATIVE)
        key = Digest::SHA256.hexdigest(@definition.target_path.to_s)
        @lock_path = File.join(root, "#{key}.lock")
        directory = Hive::ManagedDirectory.new(
          root: root,
          anchor: @home,
          label: "user-service coordination"
        )
        @journal = TransactionJournal.new(
          directory: directory, name: "#{key}.journal.json",
          definition: definition, clock: clock
        )
        @receipt = AppliedReceipt.new(
          directory: directory, name: "#{key}.receipt.json",
          definition: definition, clock: clock
        )
      end

      def with_lock
        ensure_root!
        flags = File::RDWR | File::CREAT
        flags |= File::NOFOLLOW if File.const_defined?(:NOFOLLOW)
        File.open(lock_path, flags, 0o600) do |lock|
          acquired = false
          owns_record = false
          validate_lock!(lock)
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
          validate_reclaimable_holder!(lock) unless lock.size.zero?
          write_holder(lock)
          owns_record = true
          yield self
        ensure
          clear_holder(lock) if acquired && owns_record
          lock&.flock(File::LOCK_UN)
        end
      rescue Errno::ELOOP, Errno::EACCES, Errno::EPERM => error
        raise Unsafe, "unsafe user-service lock: #{error.class}"
      end

      def clear_after_verified_removal
        journal.delete
        receipt.delete
      end

      private

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

      def ensure_root!
        cursor = @home
        ROOT_RELATIVE.split("/").each do |component|
          cursor = File.join(cursor, component)
          begin
            Dir.mkdir(cursor, 0o700)
            Hive::AtomicFile.fsync_directory(File.dirname(cursor))
          rescue Errno::EEXIST
            nil
          end
          validate_directory!(cursor)
        end
      end

      def validate_directory!(path)
        stat = File.lstat(path)
        unless stat.directory? && !stat.symlink? && stat.uid == Process.euid && (stat.mode & 0o022).zero?
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

      def write_holder(lock)
        holder = {
          "pid" => Process.pid,
          "boot_id" => boot_id,
          "process_start" => Hive::Lock.process_start_time(Process.pid) || "unavailable",
          "target_path" => @definition.target_path,
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
               holder["boot_id"].is_a?(String) && !holder["boot_id"].empty? &&
               holder["process_start"].is_a?(String) && !holder["process_start"].empty? &&
               holder["target_path"] == @definition.target_path &&
               holder["acquired_at"].is_a?(String)
          raise Unsafe, "invalid user-service lock holder record"
        end
        holder
      rescue JSON::ParserError, TypeError
        raise Unsafe, "invalid user-service lock holder record"
      end

      def monotonic
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end
    end
  end
end
