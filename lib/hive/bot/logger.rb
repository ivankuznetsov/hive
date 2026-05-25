require "json"
require "time"
require "fileutils"

module Hive
  module Bot
    class Logger
      SCHEMA = "hive-bot-log".freeze
      SCHEMA_VERSION = 1

      EVENTS = %i[
        bot_started
        bot_stopping
        poll_failure
        update_received
        update_rejected_unauthorized
        notification_sent
        notification_skipped_dedupe
        dispatched_command
        command_completed
        codex_spawned
        codex_succeeded
        codex_failed
        answer_written
        answer_skipped_already_answered
        reconnect_summary
        config_reloaded
        envelope_parse_failure
        send_failure
        callback_malformed
        pid_file_corrupted
        unknown_stage_label
        alert_store_corrupt
        deprecated_config
        fatal
      ].freeze

      attr_reader :path

      def initialize(path:, max_bytes: 10_485_760, max_files: 5)
        @path = path
        @max_bytes = max_bytes
        @max_files = max_files
        @stderr_fallback = false
        FileUtils.mkdir_p(File.dirname(path))
        @file = File.open(path, "a")
      rescue Errno::EACCES, Errno::EROFS, Errno::ENOSPC, Errno::ENOENT => e
        @file = nil
        @stderr_fallback = true
        warn "hive bot: log file #{path} is unwritable (#{e.message}); falling back to stderr"
      end

      def event(name, **attrs)
        unless EVENTS.include?(name)
          raise ArgumentError, "unknown bot log event: #{name.inspect} (valid: #{EVENTS.inspect})"
        end

        payload = {
          ts: Time.now.utc.iso8601,
          schema: SCHEMA,
          schema_version: SCHEMA_VERSION,
          event: name.to_s
        }.merge(attrs.transform_keys(&:to_sym))

        line = JSON.generate(payload)
        if @stderr_fallback
          warn line
          return
        end

        rotate_if_needed!
        @file.puts(line)
        @file.flush
      end

      def close
        @file&.close
      end

      def stderr_fallback?
        @stderr_fallback
      end

      private

      def rotate_if_needed!
        return if @file.nil?
        return if file_size_for_rotation < @max_bytes

        @file.close
        (@max_files - 2).downto(0) do |i|
          src = i.zero? ? @path : "#{@path}.#{i - 1}"
          dst = "#{@path}.#{i}"
          if i.zero?
            File.rename(@path, "#{@path}.0") if File.exist?(@path)
          elsif File.exist?(src)
            File.rename(src, dst)
          end
        end
        @file = File.open(@path, "a")
      rescue SystemCallError => e
        begin
          @file = File.open(@path, "a")
        rescue SystemCallError => reopen_err
          @file = nil
          @stderr_fallback = true
          warn "hive bot: log rotation failed (#{e.message}) and reopen failed (#{reopen_err.message}); falling back to stderr"
        end
      end

      def file_size_for_rotation
        @file.size
      rescue StandardError => e
        unless @file_size_warned
          warn "hive bot: cannot read log file size for rotation (#{e.class}: #{e.message})"
          @file_size_warned = true
        end
        0
      end
    end
  end
end
