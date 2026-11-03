require "json"
require "hive/patrol_fix/attempt_diagnostic"

module Hive
  module Attempts
    # One child-to-supervisor diagnostic frame. The bound stays below POSIX
    # PIPE_BUF so a managed worker can publish once without a concurrent drain
    # and without interleaving bytes from any inherited writer.
    module DiagnosticChannel
      module_function

      SUPERVISED_ENV = "HIVE_SUPERVISED_STAGE_RESULT_FD".freeze
      MAX_FRAME_BYTES = 3_584
      STATUSES = Hive::PatrolFix::AttemptDiagnostic::TRANSPORT_STATUSES
      ReadResult = Data.define(:document, :status)

      class Writer
        def self.for_fd(value)
          io = IO.for_fd(Integer(value), "w", autoclose: true)
          io.close_on_exec = true
          new(io)
        rescue ArgumentError, TypeError, Errno::EBADF
          nil
        end

        def initialize(io)
          @io = io
          @attempted = false
        end

        def write(document)
          raise IOError, "attempt diagnostic frame was already written" if @attempted

          @attempted = true

          DiagnosticChannel.validate_document!(document)
          frame = JSON.generate(document) + "\n"
          if frame.bytesize > MAX_FRAME_BYTES
            raise IOError, "attempt diagnostic frame exceeds #{MAX_FRAME_BYTES} bytes"
          end

          written = @io.syswrite(frame)
          raise IOError, "attempt diagnostic frame write was incomplete" unless written == frame.bytesize

          true
        ensure
          close if @attempted
        end

        def close
          @io.close unless @io.closed?
          true
        rescue IOError
          false
        end
      end

      # Install before command/provider work so the one-shot pipe cannot be
      # inherited by an agent process. It carries stage acceptance only; task
      # and launch identity remain with the supervising dispatch owner.
      def install_supervised_from_env!(environment = ENV)
        value = environment.delete(SUPERVISED_ENV)
        @supervised_writer = Writer.for_fd(value) if value
      end

      def publish_supervised_stage_result(accepted:, output_digest:)
        return false unless @supervised_writer

        writer = @supervised_writer
        @supervised_writer = nil
        writer.write("schema" => "hive-stage-result", "handled" => true,
          "accepted" => accepted, "output_digest" => output_digest)
      rescue IOError, SystemCallError
        false
      end

      def validate_document!(document)
        if document.is_a?(Hash) && document["schema"] == "hive-stage-result"
          unless document.keys.sort == %w[accepted handled output_digest schema].sort &&
                 [true, false].include?(document["accepted"]) && document["handled"] == true &&
                 document["output_digest"].to_s.match?(/\A[0-9a-f]{64}\z/)
            raise Hive::PatrolFix::AttemptDiagnostic::InvalidDiagnostic, "invalid stage result"
          end
        else
          Hive::PatrolFix::AttemptDiagnostic.validate!(document, require_log_reference: false)
        end
      end

      def read(io)
        return ReadResult.new(document: nil, status: "missing") unless io

        bytes = io.read(MAX_FRAME_BYTES + 1).to_s
        return ReadResult.new(document: nil, status: "missing") if bytes.empty?
        return ReadResult.new(document: nil, status: "oversized") if bytes.bytesize > MAX_FRAME_BYTES
        return ReadResult.new(document: nil, status: "malformed") unless bytes.end_with?("\n")

        lines = bytes.lines
        return ReadResult.new(document: nil, status: "duplicate") unless lines.length == 1

        document = JSON.parse(lines.fetch(0))
        validate_document!(document)
        ReadResult.new(document: document, status: "valid")
      rescue JSON::ParserError, Hive::PatrolFix::AttemptDiagnostic::InvalidDiagnostic
        ReadResult.new(document: nil, status: "malformed")
      rescue IOError, SystemCallError
        ReadResult.new(document: nil, status: "unavailable")
      ensure
        io&.close unless io&.closed?
      end
    end
  end
end
