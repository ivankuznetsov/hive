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
    # reads `nudge`. To avoid one process clobbering another's keys with a
    # stale in-memory copy, every operation re-reads the file from disk first
    # — the daily cadence makes the extra read negligible.
    class State
      SCHEMA_VERSION = 1
      DEFAULT_WINDOW_SEC = 86_400 # ~daily

      Nudge = Data.define(:latest, :channel, :command)

      def self.default_path
        File.join(Hive::Paths.state_home, "update_check.json")
      end

      def initialize(path: self.class.default_path, logger: nil)
        @path = path ? File.expand_path(path) : nil
        @logger = logger
        @mutex = Mutex.new
        @data = empty_data
        clean_orphaned_tmp_files!
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
        synchronize do
          load!
          @data["last_check_at"] = timestamp(now)
          persist_locked!
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
        synchronize do
          load!
          @data["last_notified_version"] = version.to_s
          persist_locked!
        end
      end

      def set_nudge(latest:, channel:, command:)
        synchronize do
          load!
          @data["nudge"] = { "latest" => latest.to_s, "channel" => channel.to_s, "command" => command.to_s }
          persist_locked!
        end
      end

      def clear_nudge!
        synchronize do
          load!
          next if @data["nudge"].nil?

          @data["nudge"] = nil
          persist_locked!
        end
      end

      def nudge
        synchronize do
          load!
          raw = @data["nudge"]
          next nil unless raw.is_a?(Hash) && !raw["latest"].to_s.empty?

          Nudge.new(latest: raw["latest"], channel: raw["channel"], command: raw["command"])
        end
      end

      private

      def synchronize(&block)
        @mutex.synchronize(&block)
      end

      def empty_data
        { "schema_version" => SCHEMA_VERSION, "last_check_at" => nil,
          "last_notified_version" => nil, "nudge" => nil }
      end

      def load!
        return unless @path && File.exist?(@path)

        raw = begin
          File.read(@path)
        rescue SystemCallError, IOError => e
          handle_corrupt!(e)
          return
        end

        parsed = JSON.parse(raw)
        raise JSON::ParserError, "invalid update_check state schema" unless valid_schema?(parsed)

        @data = empty_data.merge(parsed.slice("last_check_at", "last_notified_version", "nudge"))
      rescue JSON::ParserError, TypeError => e
        handle_corrupt!(e)
      end

      def valid_schema?(parsed)
        parsed.is_a?(Hash) && parsed["schema_version"] == SCHEMA_VERSION
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

        Dir.glob(File.join(dir, ".#{File.basename(@path)}.*.tmp")).each { |orphan| FileUtils.rm_f(orphan) }
      rescue StandardError
        nil
      end

      def persist_locked!
        return unless @path

        FileUtils.mkdir_p(File.dirname(@path))
        tmp_path = File.join(File.dirname(@path), ".#{File.basename(@path)}.#{$$}.#{Thread.current.object_id}.tmp")
        File.open(tmp_path, "w") do |f|
          f.write(JSON.pretty_generate(@data))
          f.fsync
        end
        File.rename(tmp_path, @path)
      ensure
        FileUtils.rm_f(tmp_path) if tmp_path && File.exist?(tmp_path)
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
