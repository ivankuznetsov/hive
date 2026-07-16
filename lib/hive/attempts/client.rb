require "hive/attempts/store"
require "hive/attempts/stream_log"

module Hive
  module Attempts
    ClientResult = Data.define(:status, :exit_status, :outcome, :receipt, :attempt_id)

    # Read-only attachment to a durable attempt. Closing or interrupting this
    # reader never sends a signal to the wrapper or worker group.
    class Client
      def initialize(store:, poll_interval: 0.05)
        @store = store
        @poll_interval = poll_interval
      end

      def attach(attempt_id, stdout: $stdout, stderr: $stderr)
        sequence = 0
        loop do
          StreamLog.read(log_path(attempt_id), after_sequence: sequence).each do |frame|
            target = frame.channel == "stdout" ? stdout : stderr
            target.write(frame.bytes)
            target.flush if target.respond_to?(:flush)
            sequence = frame.sequence
          end

          record = @store.fetch(attempt_id)
          raise StoreError, "unknown attempt #{attempt_id}" unless record
          if record.state == "terminal"
            receipt = record.receipt
            return ClientResult.new(
              status: :terminal, exit_status: receipt.fetch("exit_status"),
              outcome: receipt.fetch("outcome"), receipt: receipt, attempt_id: attempt_id
            )
          end
          if record.state == "lost"
            return ClientResult.new(
              status: :lost, exit_status: Hive::ExitCodes::TEMPFAIL,
              outcome: "lost", receipt: nil, attempt_id: attempt_id
            )
          end
          sleep @poll_interval
        end
      rescue Interrupt
        ClientResult.new(
          status: :detached, exit_status: 130, outcome: nil,
          receipt: nil, attempt_id: attempt_id
        )
      end

      private

      def log_path(attempt_id)
        File.join(@store.logs_root, "#{attempt_id}.frames")
      end
    end
  end
end
