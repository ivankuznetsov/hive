require "hive/attempts/api"
require "hive/command_receipt_store"

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
        attributes = {
          task: task,
          intended_stage: durable_intended_stage(task),
          argv: durable_worker_argv(task),
          interactive: true
        }
        context = defined?(Hive::CommandOperation) && Hive::CommandOperation.current_context
        @command_dispatch_context = context
        if context
          if context.retry_horizon_expires_at.to_s.empty?
            raise Hive::UsageError,
                  "keyed durable dispatch requires an absolute --retry-horizon-expires-at"
          end
          Hive::CommandReceiptStore.new.acquire_pin(
            receipt_id: context.receipt_id, principal: context.principal,
            intent_id: context.transport_request_id, intent_generation: context.ordinal,
            retry_horizon_expires_at: context.retry_horizon_expires_at
          )
          attributes[:request_id] = context.transport_request_id
        end
        result = (@attempts_api || Hive::Attempts::API.new).dispatch(**attributes)
        if @json && result.output_status == :expired
          raise Hive::ConcurrentRunError,
                "raw output for successful durable attempt #{result.attempt_id} expired; " \
                "the canonical receipt is still available and the attempt was not rerun"
        end
        handle_durable_failure!(result) unless result.exit_status.zero?

        result
      end

      def handle_durable_failure!(result)
        if result.status == :lost
          if @json && result.stdout_emitted? && !@command_dispatch_context
            exit(result.exit_status)
          end

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

        if @command_dispatch_context
          raise Hive::AttemptExecutionError.new(
            "durable attempt #{result.attempt_id} failed after buffered JSON output",
            exit_code: result.exit_status, attempt_id: result.attempt_id,
            outcome: result.outcome
          )
        end
        exit(result.exit_status)
      end
    end
  end
end
