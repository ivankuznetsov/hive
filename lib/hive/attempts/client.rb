require "hive/attempts/repository"
require "hive/attempts/contracts"

module Hive
  module Attempts
    # Read-only attachment to a durable attempt. Closing or interrupting this
    # reader never sends a signal to the wrapper or worker group. Frames and
    # their availability always come from the repository's single log-read
    # contract; the client never resolves frame paths itself.
    class Client
      def initialize(store:, poll_interval: 0.05)
        @store = store
        @poll_interval = poll_interval
      end

      def attach(attempt_id, stdout: $stdout, stderr: $stderr)
        sequence = 0
        stdout_bytes = 0
        output_status = :unavailable
        loop do
          sequence, stdout_bytes, output_status = drain_frames(
            attempt_id, sequence, stdout_bytes, stdout: stdout, stderr: stderr
          )

          record = @store.fetch(attempt_id)
          raise RepositoryError, "unknown attempt #{attempt_id}" unless record
          if record.state == "terminal"
            sequence, stdout_bytes, output_status = drain_frames(
              attempt_id, sequence, stdout_bytes, stdout: stdout, stderr: stderr
            )
            report_expired_output(stderr, attempt_id) if output_status == :expired
            receipt = record.receipt
            return ClientResult.new(
              status: :terminal, exit_status: receipt.fetch("exit_status"),
              outcome: receipt.fetch("outcome"), receipt: receipt, attempt_id: attempt_id,
              stdout_bytes: stdout_bytes, output_status: output_status
            )
          end
          if record.state == "lost"
            sequence, stdout_bytes, output_status = drain_frames(
              attempt_id, sequence, stdout_bytes, stdout: stdout, stderr: stderr
            )
            return ClientResult.new(
              status: :lost, exit_status: Hive::ExitCodes::TEMPFAIL,
              outcome: "lost", receipt: nil, attempt_id: attempt_id,
              stdout_bytes: stdout_bytes, output_status: output_status
            )
          end
          sleep @poll_interval
        end
      rescue Interrupt
        ClientResult.new(
          status: :detached, exit_status: 130, outcome: nil,
          receipt: nil, attempt_id: attempt_id, stdout_bytes: stdout_bytes,
          output_status: output_status
        )
      end

      private

      def drain_frames(attempt_id, sequence, stdout_bytes, stdout:, stderr:)
        result = @store.read_log(attempt_id, after_sequence: sequence)
        result.frames.each do |frame|
          target = frame.channel == "stdout" ? stdout : stderr
          target.write(frame.bytes)
          target.flush if target.respond_to?(:flush)
          stdout_bytes += frame.bytes.bytesize if frame.channel == "stdout"
          sequence = frame.sequence
        end
        [ sequence, stdout_bytes, result.availability ]
      end

      def report_expired_output(stderr, attempt_id)
        stderr.write(
          "hive: raw output for attempt #{attempt_id} expired; " \
          "returning its preserved receipt without rerunning it\n"
        )
        stderr.flush if stderr.respond_to?(:flush)
      end
    end
  end
end
