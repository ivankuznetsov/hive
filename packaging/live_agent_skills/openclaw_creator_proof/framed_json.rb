module HiveLiveAgentProof
  module OpenClawCreatorProof
    class FramedJson
      HEADER_BYTES = 4

      class StreamReader
        READ_CHUNK = 16 * 1024

        def initialize(max_bytes:)
          @max_bytes = max_bytes
          @buffer = +"".b
          @eof = false
        end

        def read_available(io)
          frames = []
          loop do
            chunk = io.read_nonblock(READ_CHUNK, exception: false)
            case chunk
            when :wait_readable
              break
            when nil
              @eof = true
              break
            else
              @buffer << chunk
              frames.concat(extract_frames)
            end
          end
          frames
        rescue JSON::ParserError => e
          fail_frame!("frame JSON is malformed: #{e.message}")
        end

        def eof? = @eof

        def finish!
          fail_frame!("frame is truncated") unless @buffer.empty?

          true
        end

        private

        def extract_frames
          frames = []
          loop do
            break if @buffer.bytesize < HEADER_BYTES

            length = @buffer.unpack1("N")
            fail_frame!("frame length must be positive") unless length.positive?
            fail_frame!("frame exceeds #{@max_bytes} bytes") if length > @max_bytes
            break if @buffer.bytesize < HEADER_BYTES + length

            encoded = @buffer.byteslice(HEADER_BYTES, length)
            @buffer = @buffer.byteslice(HEADER_BYTES + length..) || +"".b
            payload = JSON.parse(encoded)
            fail_frame!("frame payload must be an object") unless payload.is_a?(Hash)
            frames << payload
          end
          frames
        end

        def fail_frame!(detail)
          raise Failure.new(
            phase: "process",
            reason: "containment_failed",
            detail: detail
          )
        end
      end

      def initialize(max_bytes:)
        @max_bytes = Integer(max_bytes)
        raise ArgumentError, "frame limit must be positive" unless @max_bytes.positive?
      end

      def stream_reader
        StreamReader.new(max_bytes: @max_bytes)
      end

      def write(io, payload)
        fail_frame!("frame payload must be an object") unless payload.is_a?(Hash)

        encoded = JSON.generate(normalize_text(payload)).b
        fail_frame!("frame exceeds #{@max_bytes} bytes") if encoded.bytesize > @max_bytes

        write_all(io, [ encoded.bytesize ].pack("N"))
        write_all(io, encoded)
        io.flush
      rescue JSON::GeneratorError, TypeError => e
        fail_frame!("frame cannot be encoded: #{e.message}")
      end

      def read(io, deadline:)
        header = read_exact(io, HEADER_BYTES, deadline: deadline)
        length = header.unpack1("N")
        fail_frame!("frame length must be positive") unless length.positive?
        fail_frame!("frame exceeds #{@max_bytes} bytes") if length > @max_bytes

        payload = JSON.parse(read_exact(io, length, deadline: deadline))
        fail_frame!("frame payload must be an object") unless payload.is_a?(Hash)

        payload
      rescue JSON::ParserError => e
        fail_frame!("frame JSON is malformed: #{e.message}")
      end

      def expect_eof!(io, deadline:)
        loop do
          remaining = deadline - monotonic_now
          fail_frame!("frame stream did not terminate") unless remaining.positive?
          ready = IO.select([ io ], nil, nil, remaining)
          fail_frame!("frame stream did not terminate") unless ready

          byte = io.read_nonblock(1, exception: false)
          return true if byte.nil?
          next if byte == :wait_readable

          fail_frame!("frame stream contains trailing data")
        end
      end

      private

      def normalize_text(value)
        case value
        when Hash
          value.each_with_object({}) do |(key, nested), normalized|
            normalized[normalize_string(key)] = normalize_text(nested)
          end
        when Array
          value.map { |nested| normalize_text(nested) }
        when String
          normalize_string(value)
        else
          value
        end
      end

      def normalize_string(value)
        return value unless value.is_a?(String)

        value.dup.force_encoding(Encoding::UTF_8).scrub
      end

      def read_exact(io, length, deadline:)
        retained = +"".b
        while retained.bytesize < length
          remaining = deadline - monotonic_now
          fail_frame!("frame is truncated or timed out") unless remaining.positive?
          ready = IO.select([ io ], nil, nil, remaining)
          fail_frame!("frame is truncated or timed out") unless ready

          chunk = io.read_nonblock(length - retained.bytesize, exception: false)
          fail_frame!("frame is truncated") if chunk.nil?
          next if chunk == :wait_readable

          retained << chunk
        end
        retained
      end

      def write_all(io, bytes)
        offset = 0
        while offset < bytes.bytesize
          written = io.write(bytes.byteslice(offset, bytes.bytesize - offset))
          fail_frame!("frame write was incomplete") unless written&.positive?

          offset += written
        end
      rescue Errno::EPIPE, IOError => e
        fail_frame!("frame write failed: #{e.message}")
      end

      def fail_frame!(detail)
        raise Failure.new(
          phase: "process",
          reason: "containment_failed",
          detail: detail
        )
      end

      def monotonic_now
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end
    end
  end
end
