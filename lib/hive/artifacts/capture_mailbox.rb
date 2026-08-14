require "fileutils"
require "json"
require "securerandom"
require "tmpdir"

module Hive
  module Artifacts
    # Bounded filesystem RPC for sandboxed capture producers. Codex's managed
    # network proxy intentionally denies raw Unix sockets, so the producer
    # writes one request to a controller-owned FIFO and reads one private reply
    # FIFO. The controller remains the only process that executes capture
    # operations and records their receipts.
    class CaptureMailbox
      MAX_REQUEST_BYTES = 64 * 1024
      MAX_RESPONSE_BYTES = 512 * 1024
      READ_BYTES = 16 * 1024
      POLL_SECONDS = 0.05
      REPLY_TIMEOUT_SECONDS = 5
      REPLY_NAME = /\Areply-[0-9a-f]{24}\.fifo\z/

      attr_reader :root

      class MailboxError < Hive::Error; end

      def initialize(handler:)
        @handler = handler
        @mutex = Mutex.new
        @closed = false
      end

      def start!
        @mutex.synchronize { @closed = false }
        @root = Dir.mktmpdir("hive-capture-mailbox-")
        File.chmod(0o700, @root)
        @request_path = File.join(@root, "requests.fifo")
        File.mkfifo(@request_path, 0o600)
        @request = File.open(
          @request_path, File::RDWR | File::NONBLOCK | File::NOFOLLOW
        )
        @thread = Thread.new { serve }
        @thread.report_on_exception = false
        self
      rescue SystemCallError => e
        close
        raise MailboxError, "capture mailbox is unavailable: #{e.message}"
      end

      def close
        @mutex.synchronize { @closed = true }
        @thread&.join(1)
        @request&.close unless @request&.closed?
        remove_owned_root
        true
      rescue IOError, SystemCallError
        false
      ensure
        @request = nil
        @thread = nil
        @request_path = nil
        @root = nil
      end

      private

      def serve
        buffer = +"".b
        until closed?
          next unless IO.select([ @request ], nil, nil, POLL_SECONDS)

          begin
            buffer << @request.read_nonblock(READ_BYTES)
          rescue IO::WaitReadable
            next
          end
          if buffer.bytesize > MAX_REQUEST_BYTES && !buffer.include?("\n")
            buffer.clear
            next
          end
          while (newline = buffer.index("\n"))
            line = buffer.slice!(0, newline + 1)
            next if line.bytesize > MAX_REQUEST_BYTES

            process(line)
          end
        end
      rescue IOError, Errno::EBADF
        nil
      end

      def process(line)
        request = JSON.parse(line)
        reply = reply_path(request.delete("reply"))
        payload = @handler.call(request)
        respond(reply, payload)
      rescue JSON::ParserError, KeyError, TypeError, MailboxError => e
        respond(reply, error_payload(e.message)) if reply
      rescue StandardError
        respond(reply, error_payload("capture gateway command failed")) if reply
      end

      def reply_path(value)
        name = value.to_s
        raise MailboxError, "capture mailbox reply is invalid" unless name.match?(REPLY_NAME)

        path = File.join(@root, name)
        stat = File.lstat(path)
        unless stat.pipe? && !stat.symlink? && stat.uid == Process.uid
          raise MailboxError, "capture mailbox reply is invalid"
        end
        path
      rescue Errno::ENOENT, Errno::ELOOP
        raise MailboxError, "capture mailbox reply is unavailable"
      end

      def respond(path, payload)
        source = JSON.generate(payload) << "\n"
        if source.bytesize > MAX_RESPONSE_BYTES
          source = JSON.generate(error_payload("capture gateway response is oversized")) << "\n"
        end
        File.open(path, File::WRONLY | File::NONBLOCK | File::NOFOLLOW) do |writer|
          raise MailboxError, "capture mailbox reply is invalid" unless writer.stat.pipe?

          write_bounded(writer, source)
        end
      rescue Errno::ENOENT, Errno::ENXIO, Errno::EPIPE, Errno::ELOOP, MailboxError
        nil
      end

      def write_bounded(writer, source)
        offset = 0
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + REPLY_TIMEOUT_SECONDS
        while offset < source.bytesize
          begin
            offset += writer.write_nonblock(source.byteslice(offset, source.bytesize - offset))
          rescue IO::WaitWritable
            remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
            raise MailboxError, "capture mailbox reply timed out" unless remaining.positive?

            IO.select(nil, [ writer ], nil, [ remaining, POLL_SECONDS ].min)
          end
        end
      end

      def error_payload(message)
        { "ok" => false, "status" => 64, "error" => message.to_s.byteslice(0, 1024).to_s.scrub }
      end

      def closed?
        @mutex.synchronize { @closed }
      end

      def remove_owned_root
        return unless @root && File.directory?(@root) && !File.symlink?(@root)

        stat = File.lstat(@root)
        FileUtils.remove_entry_secure(@root) if stat.uid == Process.uid
      rescue Errno::ENOENT
        nil
      end
    end
  end
end
