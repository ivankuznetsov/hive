require "base64"
require "json"
require "fileutils"
require "time"
require "hive/attempts/output_reference"

module Hive
  module Attempts
    # Internal single-writer append-only output stream. Each frame is written
    # completely before its sequence is published so stdout/stderr ordering can
    # be replayed without making this storage format part of the public CLI contract.
    class StreamLog
      Frame = Data.define(:sequence, :timestamp, :channel, :bytes)
      CHANNELS = %w[stdout stderr supervisor].freeze

      attr_reader :path

      def self.read(path, after_sequence: 0)
        status = File.lstat(path)
        return [] if status.symlink? || !status.file?

        File.binread(path).lines.filter_map do |line|
          next unless line.end_with?("\n")

          begin
            data = JSON.parse(line)
            sequence = Integer(data.fetch("sequence"))
            next if sequence <= after_sequence
            channel = data.fetch("channel")
            next unless CHANNELS.include?(channel)

            Frame.new(
              sequence: sequence,
              timestamp: data.fetch("timestamp"),
              channel: channel,
              bytes: Base64.strict_decode64(data.fetch("data"))
            )
          rescue JSON::ParserError, KeyError, ArgumentError
            nil
          end
        end.sort_by(&:sequence)
      rescue SystemCallError, IOError
        []
      end

      def initialize(path, clock: -> { Time.now.utc })
        @path = File.expand_path(path)
        @clock = clock
        prepare_directory!
        validate_log_file! if File.exist?(@path) || File.symlink?(@path)
        flags = File::WRONLY | File::CREAT | File::APPEND
        flags |= File::NOFOLLOW if File.const_defined?(:NOFOLLOW)
        @io = File.open(@path, flags, 0o600)
        @io.chmod(0o600)
        seal_torn_tail
        @sequence = self.class.read(@path).last&.sequence.to_i
      rescue Errno::ELOOP
        raise IOError, "attempt log path is a symlink"
      end

      def append(channel, bytes)
        channel = channel.to_s
        raise ArgumentError, "unknown attempt log channel #{channel}" unless CHANNELS.include?(channel)
        raise IOError, "attempt log is closed" if @io.closed?

        @sequence += 1
        frame = JSON.generate(
          "sequence" => @sequence,
          "timestamp" => @clock.call.utc.iso8601(6),
          "channel" => channel,
          "data" => Base64.strict_encode64(bytes.to_s.b)
        ) + "\n"
        offset = 0
        while offset < frame.bytesize
          written = @io.syswrite(frame.byteslice(offset, frame.bytesize - offset))
          raise IOError, "attempt log write made no progress" unless written&.positive?

          offset += written
        end
        @io.flush
        @sequence
      end

      def close
        return if @io.closed?

        @io.flush
        @io.fsync
        @io.close
      end

      def closed? = @io.closed?

      private

      def prepare_directory!
        directory = File.dirname(@path)
        if File.symlink?(directory)
          raise IOError, "attempt log directory is a symlink"
        end

        FileUtils.mkdir_p(directory, mode: 0o700) unless File.exist?(directory)
        status = File.lstat(directory)
        raise IOError, "attempt log directory is a symlink" if status.symlink?
        raise IOError, "attempt log path parent is not a directory" unless status.directory?

        File.chmod(0o700, directory)
      end

      def validate_log_file!
        status = File.lstat(@path)
        raise IOError, "attempt log path is a symlink" if status.symlink?
        raise IOError, "attempt log path is not a regular file" unless status.file?
      end

      # A crash mid-append can leave a torn final line with no trailing newline.
      # Terminate it before the first post-reopen append so the torn bytes stay
      # an isolated unparseable line instead of fusing with the next frame.
      def seal_torn_tail
        return if File.size(@path).zero?

        last_byte = File.open(@path, "rb") do |file|
          file.seek(-1, IO::SEEK_END)
          file.read(1)
        end
        return if last_byte == "\n"

        @io.syswrite("\n")
        @io.flush
      end
    end
  end
end
