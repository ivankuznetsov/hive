require "base64"
require "json"
require "fileutils"
require "time"
require "hive/output_reference"

module Hive
  module Attempts
    # Internal append-only output stream. Cooperating writers serialize tail
    # recovery and frame publication with an advisory lock; threads sharing an
    # instance also serialize through its mutex. A forked child must open its own
    # instance rather than inherit an open StreamLog.
    class StreamLog
      Frame = Data.define(:sequence, :timestamp, :channel, :bytes)
      CHANNELS = %w[stdout stderr supervisor].freeze
      INVALIDATING_SEPARATOR = "#\n".b.freeze
      READ_CHUNK_SIZE = 64 * 1024

      attr_reader :path

      def self.read(path, after_sequence: 0)
        status = File.lstat(path)
        return [] if status.symlink? || !status.file?

        parse_frames(File.binread(path), after_sequence: after_sequence)
      rescue SystemCallError, IOError
        []
      end

      def self.parse_frames(bytes, after_sequence:)
        bytes.lines.filter_map do |line|
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
      end
      private_class_method :parse_frames

      def initialize(path, clock: -> { Time.now.utc }, custody_io: nil)
        @path = File.expand_path(path)
        @clock = clock
        @custody_io = custody_io
        @mutex = Mutex.new
        @io = nil
        @read_io = nil
        prepare_directory!
        validate_log_file! if File.exist?(@path) || File.symlink?(@path)
        @io = File.open(@path, open_flags(File::WRONLY | File::CREAT | File::APPEND), 0o600)
        @io.chmod(0o600)
        @read_io = File.open(@path, open_flags(File::RDONLY))
        validate_open_descriptors!
        with_append_lock do
          size = @io.stat.size
          @sequence = strict_frames(size).last&.sequence.to_i
          @observed_size = size
        end
      rescue Errno::ELOOP
        cleanup_failed_initialization
        raise IOError, "attempt log path is a symlink"
      rescue StandardError
        cleanup_failed_initialization
        raise
      end

      def append(channel, bytes)
        channel = channel.to_s
        raise ArgumentError, "unknown attempt log channel #{channel}" unless CHANNELS.include?(channel)

        @mutex.synchronize do
          raise IOError, "attempt log is closed" if @io.closed?

          begin
            with_append_lock do
              size = @io.stat.size
              sealed = seal_torn_tail(size)
              size = @io.stat.size if sealed
              reconcile_sequence(size) if sealed || @observed_size.nil? || size != @observed_size

              next_sequence = @sequence + 1
              frame = JSON.generate(
                "sequence" => next_sequence,
                "timestamp" => @clock.call.utc.iso8601(6),
                "channel" => channel,
                "data" => Base64.strict_encode64(bytes.to_s.b)
              ) + "\n"
              write_complete(frame)
              @io.flush
              @sequence = next_sequence
              @observed_size = @io.stat.size
              next_sequence
            end
          rescue StandardError
            @observed_size = nil
            raise
          end
        end
      end

      def close
        @mutex.synchronize do
          return if @io.closed?

          close_resources
        end
      end

      def closed? = @mutex.synchronize { @io.closed? }

      private

      def open_flags(flags)
        File.const_defined?(:NOFOLLOW) ? flags | File::NOFOLLOW : flags
      end

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

      def validate_open_descriptors!
        append_status = @io.stat
        read_status = @read_io.stat
        unless append_status.file? && read_status.file? &&
               append_status.dev == read_status.dev && append_status.ino == read_status.ino
          raise IOError, "attempt log descriptors do not reference the same regular file"
        end
      end

      def with_append_lock
        locked = false
        primary_error = nil
        acquired = @io.flock(File::LOCK_EX)
        raise IOError, "attempt log lock could not be acquired" unless acquired

        locked = true
        yield
      rescue StandardError => error
        primary_error = error
        raise
      ensure
        if locked
          begin
            released = @io.flock(File::LOCK_UN)
            raise IOError, "attempt log lock could not be released" unless released
          rescue StandardError
            raise unless primary_error
          end
        end
      end

      # A crash mid-append can leave an unterminated final line. The non-JSON
      # sentinel keeps even a byte-complete but unconfirmed frame unreadable.
      def seal_torn_tail(size)
        return false if size.zero?

        last_byte = @read_io.pread(1, size - 1)
        unless last_byte&.bytesize == 1
          raise IOError, "attempt log ended before its reported boundary"
        end
        return false if last_byte == "\n"

        write_complete(INVALIDATING_SEPARATOR)
        @io.flush
        true
      end

      def reconcile_sequence(size)
        @sequence = strict_frames(size).last&.sequence.to_i
        @observed_size = size
      end

      def strict_frames(size)
        bytes = +"".b
        offset = 0
        while offset < size
          chunk = @read_io.pread([ READ_CHUNK_SIZE, size - offset ].min, offset)
          if chunk.nil? || chunk.empty?
            raise IOError, "attempt log ended before its reported boundary"
          end

          bytes << chunk
          offset += chunk.bytesize
        end

        self.class.send(:parse_frames, bytes, after_sequence: 0)
      end

      def write_complete(bytes)
        offset = 0
        while offset < bytes.bytesize
          written = @io.syswrite(bytes.byteslice(offset, bytes.bytesize - offset))
          raise IOError, "attempt log write made no progress" unless written&.positive?

          offset += written
        end
      end

      def cleanup_failed_initialization
        close_quietly(@read_io)
        close_quietly(@io)
        close_quietly(@custody_io)
      end

      def close_quietly(io)
        io&.close unless io&.closed?
      rescue StandardError
        nil
      end

      def close_resources
        error = nil
        begin
          @io.flush
          @io.fsync
        rescue StandardError => close_error
          error ||= close_error
        end

        [ @read_io, @io ].each do |io|
          begin
            io.close unless io.closed?
          rescue StandardError => close_error
            error ||= close_error
          end
        end

        if @custody_io
          begin
            @custody_io.flock(File::LOCK_UN) unless @custody_io.closed?
          rescue StandardError => close_error
            error ||= close_error
          end
          begin
            @custody_io.close unless @custody_io.closed?
          rescue StandardError => close_error
            error ||= close_error
          end
        end

        raise error if error
      end
    end
  end
end
