require "json"
require "fileutils"
require "time"
require "hive/paths"

module Hive
  module UpdateCheck
    # Persists the daemon's update-check bookkeeping: when it last probed
    # GitHub (throttle), the last version it notified about (de-dupe), and the
    # active nudge payload the TUI footer renders. JSON on disk, atomic write,
    # fail-closed load (a corrupt file degrades to empty rather than raising).
    # Mirrors Hive::Bot::AlertStore's persistence discipline.
    #
    # This file is shared across processes: the daemon writes `nudge` +
    # `last_check_at`, the bot writes `last_notified_version`, and the TUI
    # reads `nudge`. Mutating ops hold an exclusive `flock` on a sibling
    # `<path>.lock` across the whole read-modify-write so two processes can't
    # clobber each other's keys (an in-process Mutex alone wouldn't span
    # processes). Reads are lock-free — `persist_locked!`'s atomic rename means
    # a reader always sees a complete old-or-new file. If the lock can't be
    # acquired (exotic FS), ops degrade to best-effort without it.
    class State
      SCHEMA_VERSION = 1
      DEFAULT_WINDOW_SEC = 86_400 # ~daily
      STALE_TMP_SEC = 60 # only sweep orphan tmp files older than this

      Nudge = Data.define(:latest, :channel, :command)

      def self.default_path
        File.join(Hive::Paths.state_home, "update_check.json")
      end

      def initialize(
        path: self.class.default_path, logger: nil,
        cleanup_orphans: true
      )
        @path = path ? File.expand_path(path) : nil
        @logger = logger
        @mutex = Mutex.new
        @data = empty_data
        # Set true when the on-disk file carries a NEWER schema_version than
        # this process understands: read what we recognize, but never write
        # back (overwriting would downgrade a newer process's state).
        @suspend_writes = false
        clean_orphaned_tmp_files! if cleanup_orphans
        load!
      end

      # Enough time elapsed since the last check to probe again? Always true
      # when never checked (e.g. on daemon start).
      def due?(now, window: DEFAULT_WINDOW_SEC)
        synchronize do
          load!
          last = parse_time(@data["last_check_at"])
          last.nil? || (now - last) >= window
        end
      end

      def record_check!(now)
        with_lock do
          synchronize do
            load!
            @data["last_check_at"] = timestamp(now)
            persist_locked!
          end
        end
      end

      # Have we already notified about this version? De-dupes the bot push so
      # it fires once per newly-seen release, not once per tick.
      def should_notify?(version)
        synchronize do
          load!
          @data["last_notified_version"].to_s != version.to_s
        end
      end

      def record_notified!(version)
        with_lock do
          synchronize do
            load!
            @data["last_notified_version"] = version.to_s
            persist_locked!
          end
        end
      end

      def set_nudge(latest:, channel:, command:)
        with_lock do
          synchronize do
            load!
            @data["nudge"] = { "latest" => latest.to_s, "channel" => channel.to_s, "command" => command.to_s }
            persist_locked!
          end
        end
      end

      def clear_nudge!
        with_lock do
          synchronize do
            load!
            next if @data["nudge"].nil?

            @data["nudge"] = nil
            persist_locked!
          end
        end
      end

      def nudge
        synchronize do
          load!
          raw = @data["nudge"]
          # Require both latest AND command: a hand-edited/partial file with a
          # version but no command would otherwise render "update X.Y.Z: ".
          next nil unless raw.is_a?(Hash) && !raw["latest"].to_s.empty? && !raw["command"].to_s.empty?

          Nudge.new(latest: raw["latest"], channel: raw["channel"], command: raw["command"])
        end
      end

      private

      def synchronize(&block)
        @mutex.synchronize(&block)
      end

      # Hold an exclusive cross-process lock around a read-modify-write. The
      # block runs exactly once whether or not the lock was acquired — a lock
      # failure logs and degrades to best-effort rather than crashing a tick.
      def with_lock
        return yield unless @path

        lock = acquire_lock
        begin
          yield
        ensure
          release_lock(lock)
        end
      end

      def acquire_lock
        FileUtils.mkdir_p(File.dirname(@path))
        handle = File.open("#{@path}.lock", File::RDWR | File::CREAT, 0o600)
        handle.flock(File::LOCK_EX)
        handle
      rescue SystemCallError, IOError => e
        @logger&.event(:update_check_state_lock_error, path: @path,
                                                        error_class: e.class.name, message: e.message)
        nil
      end

      def release_lock(handle)
        return unless handle

        handle.flock(File::LOCK_UN)
        handle.close
      rescue StandardError
        nil
      end

      def empty_data
        { "schema_version" => SCHEMA_VERSION, "last_check_at" => nil,
          "last_notified_version" => nil, "nudge" => nil }
      end

      def load!
        @suspend_writes = false
        return unless @path && File.exist?(@path)

        raw = begin
          File.read(@path)
        rescue SystemCallError, IOError => e
          handle_corrupt!(e)
          return
        end

        parsed = JSON.parse(raw)
        version = parsed.is_a?(Hash) ? parsed["schema_version"] : nil
        raise JSON::ParserError, "invalid update_check state schema" unless version.is_a?(Integer)

        if version > SCHEMA_VERSION
          # Forward-compat: a newer hive wrote this. Read recognized keys but
          # suspend writes so a rolling micro-release upgrade can't have an
          # older process clobber the newer file (regenerable, but churny).
          @suspend_writes = true
        elsif version < SCHEMA_VERSION
          # No older schema exists yet; until a real migration path is needed,
          # an older version is treated as corrupt and reset.
          raise JSON::ParserError, "unsupported update_check schema_version #{version}"
        end

        @data = empty_data.merge(parsed.slice("last_check_at", "last_notified_version", "nudge"))
      rescue JSON::ParserError, TypeError => e
        handle_corrupt!(e)
      end

      def handle_corrupt!(error)
        @logger&.event(:update_check_state_corrupt, path: @path,
                                                     error_class: error.class.name, message: error.message)
        @data = empty_data
      end

      # SIGKILL/power-loss between write(tmp) and rename leaves a hidden tmp
      # in the parent dir; sweep stragglers on construction (best-effort).
      def clean_orphaned_tmp_files!
        return unless @path

        dir = File.dirname(@path)
        return unless File.directory?(dir)

        # Only reap stragglers older than the stale window — a fresh tmp may
        # be another live process's in-flight write, and rm-ing it would
        # ENOENT its rename and lose that write.
        Dir.glob(File.join(dir, ".#{File.basename(@path)}.*.tmp")).each do |orphan|
          FileUtils.rm_f(orphan) if (Time.now - File.mtime(orphan)) > STALE_TMP_SEC
        rescue SystemCallError
          next
        end
      rescue StandardError => e
        # Best-effort, but log it: a persistently failing sweep (broken
        # permissions on the state dir) would otherwise silently leak tmp
        # files forever with no diagnostic.
        @logger&.event(:update_check_tmp_sweep_error, path: @path,
                                                      error_class: e.class.name, message: e.message)
      end

      def persist_locked!
        return unless @path
        return if @suspend_writes

        FileUtils.mkdir_p(File.dirname(@path))
        tmp_path = File.join(File.dirname(@path), ".#{File.basename(@path)}.#{$$}.#{Thread.current.object_id}.tmp")
        File.open(tmp_path, "w") do |f|
          f.write(JSON.pretty_generate(@data))
          f.fsync
        end
        File.rename(tmp_path, @path)
        fsync_dir(File.dirname(@path))
      rescue SystemCallError, IOError => e
        # A broken/read-only/full state dir must not crash a daemon tick or a
        # bot loop. Log and degrade — the in-memory value still serves this
        # process; callers guard against re-spam with their own latches.
        @logger&.event(:update_check_state_write_error, path: @path,
                                                         error_class: e.class.name, message: e.message)
      ensure
        FileUtils.rm_f(tmp_path) if tmp_path && File.exist?(tmp_path)
      end

      # Directory fsync after rename so the rename is durable on journaled
      # filesystems (matches Hive::Bot::AlertStore). Best-effort.
      def fsync_dir(dir)
        Dir.open(dir) { |d| d.fsync }
      rescue StandardError
        nil
      end

      def timestamp(time)
        time.utc.iso8601
      end

      def parse_time(value)
        return nil if value.nil? || value.to_s.empty?

        Time.parse(value.to_s)
      rescue ArgumentError
        nil
      end
    end
  end
end
