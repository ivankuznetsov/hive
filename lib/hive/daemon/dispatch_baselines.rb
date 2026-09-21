require "json"
require "fileutils"
require "time"
require "hive/paths"
require "hive/atomic_file"

module Hive
  module Daemon
    # Persists the daemon's first-sight dispatch baselines — the
    # `[project, slug] => state_file_mtime` map that `ConcurrencyController`
    # holds in memory and `Policy#decide_edit` consults to decide whether a
    # `needs_input` row has fresh user input. That map is otherwise lost on
    # every daemon restart, which re-strands already-answered tasks (a user
    # answer written before the restart stops looking "newer than baseline").
    # Persisting it across restarts is the fix.
    #
    # The daemon owns the complete map and is the only writer. AtomicFile
    # supplies crash-safe replacement; a second per-file lock adds no custody.
    # Mtimes retain microseconds so same-second operator edits stay visible.
    class DispatchBaselines
      SCHEMA_VERSION = 1
      STALE_TMP_SEC = 60 # only sweep orphan tmp files older than this

      def self.default_path
        File.join(Hive::Paths.state_home, "daemon_dispatch_baselines.json")
      end

      def initialize(path: self.class.default_path, logger: nil)
        @path = path ? File.expand_path(path) : nil
        @logger = logger
        # Set true when the on-disk file carries a NEWER schema_version than
        # this process understands: read what we recognize, but never write
        # back (a rolling micro-release upgrade must not let an older process
        # downgrade a newer file).
        @suspend_writes = false
        clean_orphaned_tmp_files!
      end

      # Load the persisted baselines as { [project, slug] => Time }.
      # Fail-closed: a missing file, unreadable file, non-JSON, wrong shape,
      # unrecognized schema_version, or non-Array `baselines` all return {}.
      # Individual entries with a missing project/slug or unparseable mtime
      # are dropped; well-formed siblings are kept.
      def load
        @suspend_writes = false
        unless @path && File.exist?(@path)
          emit_loaded(0)
          return {}
        end

        parsed = JSON.parse(File.read(@path))
        return reset_corrupt("root is not a Hash") unless parsed.is_a?(Hash)

        version = parsed["schema_version"]
        return reset_corrupt("missing/invalid schema_version") unless version.is_a?(Integer)

        if version > SCHEMA_VERSION
          # A NEWER hive wrote this. Suspend writes so we don't clobber it on
          # downgrade. Emit a typed event — otherwise the suspended state is
          # indistinguishable from healthy persistence and the very regression
          # this file exists to prevent (re-stranding answered tasks on
          # restart) returns silently. The operator needs a positive signal.
          @suspend_writes = true
          @logger&.event(:daemon_dispatch_baselines_newer_schema_suspended,
                         path: @path, on_disk_version: version, supported_version: SCHEMA_VERSION)
        end

        entries = parsed["baselines"]
        unless entries.is_a?(Array)
          emit_loaded(0)
          return {}
        end

        loaded = entries.each_with_object({}) do |entry, acc|
          next unless entry.is_a?(Hash)

          project = entry["project"]
          slug = entry["slug"]
          mtime = parse_time(entry["mtime"])
          next if project.nil? || slug.nil? || mtime.nil?

          acc[[ project, slug ]] = mtime
        end
        emit_loaded(loaded.size)
        loaded
      rescue JSON::ParserError, TypeError, SystemCallError, IOError => e
        handle_corrupt!(e)
        {}
      end

      # A failed write must not stop task advancement; the previous persisted
      # baseline remains usable and the failure is visible in the daemon log.
      def write(map)
        return unless @path
        return if @suspend_writes

        persist!(map)
      rescue StandardError => e
        # Defense in depth against everything `persist!`'s narrower
        # `SystemCallError/IOError` rescue doesn't catch — programmer errors
        # (`NoMethodError` from a future API change), encoding issues
        # (`Encoding::CompatibilityError` on a non-UTF-8 project name), JSON
        # serialization failures (`JSON::GeneratorError`) — so a single bad
        # value can't crash a daemon tick. NOT silent: we surface it as a
        # typed event so the operator sees persistence is broken even though
        # dispatch kept running. Without this, the very regression this whole
        # file exists to prevent would return invisibly on the next restart.
        @logger&.event(:daemon_dispatch_baselines_unexpected_error,
                       path: @path, error_class: e.class.name, message: e.message)
        nil
      end

      private

      def reset_corrupt(reason)
        @logger&.event(:daemon_dispatch_baselines_corrupt, path: @path, reason: reason)
        emit_loaded(0)
        {}
      end

      # Positive boot-time signal so an operator tailing daemon.log can confirm
      # persistence is actually in use (entry count) and whether downgrade
      # protection has kicked in (@suspend_writes). Without this, a silent
      # failure (corrupt file, newer-schema suspend, missing file with wrong
      # permissions) is indistinguishable from a healthy empty start.
      def emit_loaded(count)
        @logger&.event(:daemon_dispatch_baselines_loaded,
                       path: @path, count: count, suspend_writes: @suspend_writes)
      end

      def handle_corrupt!(error)
        @logger&.event(:daemon_dispatch_baselines_corrupt, path: @path,
                                                            error_class: error.class.name, message: error.message)
      end

      def persist!(map)
        Hive::AtomicFile.write(@path, JSON.generate(envelope(map)))
        Hive::AtomicFile.fsync_directory(File.dirname(@path))
      rescue SystemCallError, IOError => e
        @logger&.event(:daemon_dispatch_baselines_write_error, path: @path,
                       error_class: e.class.name, message: e.message)
      end

      def envelope(map)
        baselines = map.map do |(project, slug), mtime|
          { "project" => project, "slug" => slug, "mtime" => timestamp(mtime) }
        end
        { "schema_version" => SCHEMA_VERSION, "baselines" => baselines }
      end

      # SIGKILL/power-loss between write(tmp) and rename leaves a hidden tmp in
      # the parent dir; sweep stragglers older than the stale window on
      # construction (a fresh tmp may be another in-flight write).
      def clean_orphaned_tmp_files!
        return unless @path

        dir = File.dirname(@path)
        return unless File.directory?(dir)

        Dir.glob(File.join(dir, ".#{File.basename(@path)}.{*.tmp,tmp.*}")).each do |orphan|
          FileUtils.rm_f(orphan) if (Time.now - File.mtime(orphan)) > STALE_TMP_SEC
        rescue SystemCallError
          next
        end
      rescue StandardError => e
        @logger&.event(:daemon_dispatch_baselines_tmp_sweep_error, path: @path,
                                                                   error_class: e.class.name, message: e.message)
      end

      # Microsecond resolution. See class doc for why persisted baselines keep
      # more precision than the internal task-graph mtime string.
      def timestamp(time)
        time.utc.iso8601(6)
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
