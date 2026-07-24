require "hive/attempts/store"
require "hive/attempts/stream_log"
require "hive/attempts/contracts"

module Hive
  module Attempts
    # Read-only attachment to a durable attempt. Closing or interrupting this
    # reader never sends a signal to the wrapper or worker group.
    class Client
      def initialize(store:, poll_interval: 0.05)
        @store = store
        @poll_interval = poll_interval
      end

      def attach(attempt_id, stdout: $stdout, stderr: $stderr)
        sequence = 0
        stdout_bytes = 0
        loop do
          sequence, stdout_bytes = drain_frames(
            attempt_id, sequence, stdout_bytes, stdout: stdout, stderr: stderr
          )

          record = @store.fetch(attempt_id)
          raise StoreError, "unknown attempt #{attempt_id}" unless record
          if record.state == "terminal"
            sequence, stdout_bytes = drain_frames(
              attempt_id, sequence, stdout_bytes, stdout: stdout, stderr: stderr
            )
            receipt = record.receipt
            return ClientResult.new(
              status: :terminal, exit_status: receipt.fetch("exit_status"),
              outcome: receipt.fetch("outcome"), receipt: receipt, attempt_id: attempt_id,
              stdout_bytes: stdout_bytes
            )
          end
          if record.state == "lost"
            sequence, stdout_bytes = drain_frames(
              attempt_id, sequence, stdout_bytes, stdout: stdout, stderr: stderr
            )
            return ClientResult.new(
              status: :lost, exit_status: Hive::ExitCodes::TEMPFAIL,
              outcome: "lost", receipt: nil, attempt_id: attempt_id,
              stdout_bytes: stdout_bytes
            )
          end
          sleep @poll_interval
        end
      rescue Interrupt
        ClientResult.new(
          status: :detached, exit_status: 130, outcome: nil,
          receipt: nil, attempt_id: attempt_id, stdout_bytes: stdout_bytes
        )
      end

      private

      def drain_frames(attempt_id, sequence, stdout_bytes, stdout:, stderr:)
        StreamLog.read(log_path(attempt_id), after_sequence: sequence).each do |frame|
          target = frame.channel == "stdout" ? stdout : stderr
          target.write(frame.bytes)
          target.flush if target.respond_to?(:flush)
          stdout_bytes += frame.bytes.bytesize if frame.channel == "stdout"
          sequence = frame.sequence
        end
        [ sequence, stdout_bytes ]
      end

      def log_path(attempt_id)
        File.join(@store.logs_root, "#{attempt_id}.frames")
      end
    end
  end
end
