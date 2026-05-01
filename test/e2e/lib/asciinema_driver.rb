require "json"
require "fileutils"
require "open3"
require "rubygems"
require "shellwords"

module Hive
  module E2E
    class AsciinemaDriver
      MIN_VERSION = Gem::Version.new("2.4.0")

      class Unavailable < StandardError; end

      attr_reader :cast_path

      def self.available?
        _out, _err, status = Open3.capture3(binary, "--version")
        status.success?
      rescue Errno::ENOENT
        false
      end

      def self.version
        out, _err, status = Open3.capture3(binary, "--version")
        return nil unless status.success?

        text = out.split(/\s+/).find { |part| part.match?(/\A\d+\.\d+(?:\.\d+)?/) }
        text ? Gem::Version.new(text) : nil
      rescue Errno::ENOENT
        nil
      end

      def self.binary
        ENV["HIVE_ASCIINEMA_BIN"].to_s.empty? ? "asciinema" : ENV["HIVE_ASCIINEMA_BIN"]
      end

      def initialize(socket_name:, session_name:, cast_path:, rows: 50, cols: 200)
        @socket_name = socket_name
        @session_name = session_name
        @cast_path = cast_path
        @rows = rows
        @cols = cols
        @pid = nil
        preflight!
      end

      def start
        return if @pid

        FileUtils.mkdir_p(File.dirname(@cast_path))
        command = "tmux -L #{@socket_name.shellescape} attach -t #{@session_name.shellescape}"
        @pid = Process.spawn(
          self.class.binary, "rec", "--overwrite",
          "--rows", @rows.to_s, "--cols", @cols.to_s,
          "--output-format=asciicast-v2",
          "--command", command,
          @cast_path,
          out: File::NULL,
          err: File::NULL,
          pgroup: true
        )
      end

      def stop
        return unless @pid

        # Signal the entire process group so the tmux attach child started by
        # asciinema dies with the recorder. Without -pgid the attach lingers and
        # holds the cast file open, racing the manifest pass.
        pgid = begin
          Process.getpgid(@pid)
        rescue Errno::ESRCH
          @pid
        end
        begin
          Process.kill("TERM", -pgid)
        rescue Errno::ESRCH
          nil
        end

        deadline = Time.now + 2
        reaped = false
        loop do
          _, status = Process.wait2(@pid, Process::WNOHANG)
          if status
            reaped = true
            break
          end
          break if Time.now >= deadline

          sleep 0.05
        end

        # Only escalate to KILL if the WNOHANG poll never saw the process exit.
        # Otherwise the unconditional KILL/wait races and raises ESRCH/ECHILD.
        unless reaped
          begin
            Process.kill("KILL", -pgid)
          rescue Errno::ESRCH
            nil
          end
          begin
            Process.wait(@pid)
          rescue Errno::ECHILD
            nil
          end
        end
      ensure
        @pid = nil
      end

      def integrity_status
        return :absent unless File.exist?(@cast_path)

        first = File.open(@cast_path, &:readline)
        header = JSON.parse(first)
        header["version"].to_i == 2 ? :ok : :corrupt
      rescue StandardError
        :corrupt
      end

      private

      def preflight!
        found = self.class.version
        raise Unavailable, "asciinema >= 2.4 is required for TUI e2e casts" unless found && found >= MIN_VERSION
      end
    end
  end
end
