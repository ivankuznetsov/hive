require "hive/attempts/api"

module Hive
  module Attempts
    # Shared command-side dispatch and failure interpretation for public Hive
    # commands backed by durable attempts. Consumers resolve the task and
    # provide the intended stage plus worker argv; this module owns the single
    # attach-result policy, including JSON single-document behavior.
    module CommandDispatch
      private

      def dispatch_durable
        task = resolve_task
        result = (@attempts_api || Hive::Attempts::API.new).dispatch(
          task: task,
          intended_stage: durable_intended_stage(task),
          argv: durable_worker_argv(task),
          interactive: true
        )
        handle_durable_failure!(result) unless result.exit_status.zero?

        result
      end

      def handle_durable_failure!(result)
        if result.status == :lost
          exit(result.exit_status) if @json && result.stdout_emitted?

          raise Hive::ConcurrentRunError,
                "durable attempt lost before producing a receipt for #{@target}: #{result.attempt_id}"
        end

        if @json && !result.stdout_emitted?
          raise Hive::AttemptExecutionError.new(
            "durable attempt #{result.attempt_id} finished with #{result.outcome || 'an error'} " \
            "(exit #{result.exit_status}) before emitting JSON",
            exit_code: result.exit_status,
            attempt_id: result.attempt_id,
            outcome: result.outcome
          )
        end

        exit(result.exit_status)
      end
    end
  end
end
