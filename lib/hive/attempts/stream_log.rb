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
      APPEND_LOCK_TIMEOUT_SEC = 5.0
      APPEND_LOCK_POLL_SEC = 0.01

      attr_reader :path

      def self.read(path, after_sequence: 0)
        status = File.lstat(path)
        return [] if status.symlink? || !status.file?

        parse_frames(File.binread(path), after_sequence: after_sequence)
      rescue SystemCallError, IOError
        []
      end

      # @api private
      def self.parse_frames(bytes, after_sequence:)
        bytes.lines.filter_map do |line|
          next unless line.end_with?("\n")

          begin
            data, sequence = parse_frame_fields(line)
            next if sequence <= after_sequence

            Frame.new(
              sequence: sequence,
              timestamp: data.fetch("timestamp"),
              channel: data.fetch("channel"),
              bytes: Base64.strict_decode64(data.fetch("data"))
            )
          rescue JSON::ParserError, KeyError, ArgumentError, TypeError
            nil
          end
        end.sort_by(&:sequence)
      end

      # @api private
      def self.parse_frame_fields(line)
        data = JSON.parse(line)
        sequence = Integer(data.fetch("sequence"))
        channel = data.fetch("channel")
        encoded = data.fetch("data")
        raise TypeError, "frame data must be a string" unless encoded.is_a?(String)
        raise ArgumentError, "unknown frame channel" unless CHANNELS.include?(channel)

        [ data, sequence ]
      end

      # @api private
      def self.valid_base64?(encoded)
        encoded.match?(
          %r{\A(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/][AQgw]==|[A-Za-z0-9+/]{2}[AEIMQUYcgkosw048]=)?\z}
        )
      end

      def initialize(path, clock: -> { Time.now.utc }, custody_io: nil,
                     lock_timeout: APPEND_LOCK_TIMEOUT_SEC)
        @path = File.expand_path(path)
        @clock = clock
        @custody_io = custody_io
        @lock_timeout = lock_timeout
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
          reconcile_sequence(@io.stat.size)
        end
      rescue Errno::ELOOP
        cleanup_failed_initialization
        raise IOError, "attempt log path is a symlink"
      rescue Exception # rubocop:disable Lint/RescueException -- every failed construction releases custody
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
              size += INVALIDATING_SEPARATOR.bytesize if sealed
              reconcile_sequence(size) if @observed_size.nil? || size != @observed_size

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
              @observed_size = size + frame.bytesize
              next_sequence
            end
          rescue Exception # rubocop:disable Lint/RescueException -- snapshot invalidation must cover interrupts
            @observed_size = nil
            raise
          end
        end
      end

      def close
        @mutex.synchronize do
          return if resources_closed?

          close_resources
        end
      end

      def closed? = @mutex.synchronize { resources_closed? }

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
        primary_error = nil
        release_needed = true
        deadline = monotonic_now + @lock_timeout
        until @io.flock(File::LOCK_EX | File::LOCK_NB)
          remaining = deadline - monotonic_now
          if remaining <= 0
            raise IOError, "attempt log lock held longer than #{@lock_timeout}s"
          end

          sleep([ APPEND_LOCK_POLL_SEC, remaining ].min)
        end
        yield
      rescue Exception => error # rubocop:disable Lint/RescueException -- preserve every initiating unwind
        primary_error = error
        raise
      ensure
        # release_needed is set before flock so an asynchronous unwind after
        # acquisition cannot strand the kernel lock. LOCK_UN is harmless when
        # this descriptor never acquired the lock.
        if release_needed
          begin
            @io.flock(File::LOCK_UN)
          rescue Exception # rubocop:disable Lint/RescueException -- cleanup must not replace an unwind
            replace_append_descriptor_after_unlock_failure
            raise unless primary_error
          end
        end
      end

      # A crash mid-append can leave an unterminated final line. The non-JSON
      # sentinel keeps even a byte-complete but unconfirmed frame unreadable.
      def seal_torn_tail(size)
        return false if size.zero?

        last_byte = @read_io.pread(1, size - 1)
        raise IOError, "attempt log ended before its reported boundary" unless last_byte.bytesize == 1
        return false if last_byte == "\n"

        write_complete(INVALIDATING_SEPARATOR)
        @io.flush
        true
      rescue EOFError
        raise IOError, "attempt log ended before its reported boundary"
      end

      def reconcile_sequence(size)
        @sequence = strict_max_sequence(size)
        @observed_size = size
      end

      def strict_max_sequence(size)
        pending = +"".b
        offset = 0
        max_sequence = 0
        while offset < size
          length = [ READ_CHUNK_SIZE, size - offset ].min
          chunk = @read_io.pread(length, offset)
          raise IOError, "attempt log ended before its reported boundary" unless chunk.bytesize == length

          pending << chunk
          offset += chunk.bytesize
          while (newline = pending.index("\n"))
            sequence = strict_frame_sequence(pending.slice!(0, newline + 1))
            max_sequence = sequence if sequence && sequence > max_sequence
          end
        end

        max_sequence
      rescue EOFError
        raise IOError, "attempt log ended before its reported boundary"
      end

      def strict_frame_sequence(line)
        data, sequence = self.class.parse_frame_fields(line)
        data.fetch("timestamp")
        encoded = data.fetch("data")
        return nil unless sequence.positive? && self.class.valid_base64?(encoded)

        sequence
      rescue JSON::ParserError, KeyError, ArgumentError, TypeError
        nil
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
        run_cleanup_steps(
          -> { @read_io&.close unless @read_io&.closed? },
          -> { @io&.close unless @io&.closed? },
          -> { @custody_io&.close unless @custody_io&.closed? }
        )
      end

      def close_resources
        # Preserve the historical retry contract: a flush/fsync failure leaves
        # the writer open so Supervisor can append its terminal diagnostic.
        unless @io.closed?
          @io.flush
          @io.fsync
        end

        error = run_cleanup_steps(
          -> { @read_io.close unless @read_io.closed? },
          -> { @io.close unless @io.closed? },
          -> { @custody_io.flock(File::LOCK_UN) if @custody_io && !@custody_io.closed? },
          -> { @custody_io.close if @custody_io && !@custody_io.closed? }
        )

        raise error if error
      end

      def resources_closed?
        @io.closed? && @read_io.closed? && (!@custody_io || @custody_io.closed?)
      end

      def run_cleanup_steps(*steps)
        first_error = nil
        steps.each do |step|
          begin
            step.call
          rescue Exception => error # rubocop:disable Lint/RescueException -- finish cleanup before reraising
            first_error ||= error
          end
        end
        first_error
      end

      def replace_append_descriptor_after_unlock_failure
        failed_io = @io
        replacement = nil
        begin
          failed_io.close unless failed_io.closed?
        rescue StandardError
          nil
        end
        return unless failed_io&.closed?

        replacement = File.open(@path, open_flags(File::WRONLY | File::APPEND))
        replacement_status = replacement.stat
        read_status = @read_io.stat
        unless replacement_status.file? && replacement_status.dev == read_status.dev &&
               replacement_status.ino == read_status.ino
          return
        end
        @io = replacement
        replacement = nil
      rescue StandardError
        nil
      ensure
        begin
          replacement&.close unless replacement&.closed?
        rescue StandardError
          nil
        end
      end

      def monotonic_now
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end
    end
  end
end
