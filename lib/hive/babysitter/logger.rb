require "json"
require "time"
require "fileutils"

module Hive
  module Babysitter
    class Logger
      SCHEMA = "hive-babysitter-log".freeze
      SCHEMA_VERSION = 1

      EVENTS = %i[
        dispatcher_started
        dispatcher_stopping
        tick_begin
        tick_end
        config_reloaded
        project_skipped
        project_tick
        fatal
      ].freeze

      attr_reader :path

      def initialize(path:, max_bytes: 10_485_760, max_files: 5)
        @path = path
        @max_bytes = max_bytes
        @max_files = max_files
        @stderr_fallback = false
        @rotation_warned = false
        FileUtils.mkdir_p(File.dirname(path))
        @file = File.open(path, "a")
      rescue Errno::EACCES, Errno::EROFS, Errno::ENOSPC, Errno::ENOENT => e
        @file = nil
        @stderr_fallback = true
        warn "hive babysitter: log file #{path} is unwritable (#{e.message}); falling back to stderr"
      end

      def event(name, **attrs)
        unless EVENTS.include?(name)
          raise ArgumentError, "unknown babysitter log event: #{name.inspect} (valid: #{EVENTS.inspect})"
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
        if @stderr_fallback
          warn line
          return
        end

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
        if @max_files <= 1
          # Keep only the current log: there is no `.N` ring to maintain,
          # so unlink the over-cap file and reopen fresh. The rename ring
          # below is a no-op when max_files == 1 ((@max_files - 2).downto(0)
          # iterates over nothing), which left the file at its current size
          # and re-fired rotation on every subsequent event.
          File.delete(@path) if File.exist?(@path)
        else
          (@max_files - 2).downto(0) do |i|
            src = i.zero? ? @path : "#{@path}.#{i - 1}"
            dst = "#{@path}.#{i}"
            if i.zero?
              File.rename(@path, "#{@path}.0") if File.exist?(@path)
            elsif File.exist?(src)
              File.rename(src, dst)
            end
          end
        end
        @file = File.open(@path, "a")
      rescue SystemCallError => e
        unless @rotation_warned
          warn "hive babysitter: log rotation failed (#{e.class}: #{e.message}); continuing without rotation"
          @rotation_warned = true
        end
        begin
          @file = File.open(@path, "a")
        rescue SystemCallError => reopen_err
          @file = nil
          @stderr_fallback = true
          warn "hive babysitter: log rotation reopen failed (#{reopen_err.message}); falling back to stderr"
        end
      end

      def file_size_for_rotation
        @file.size
      rescue StandardError
        0
      end
    end
  end
end
