require "json"
require "stringio"
require "hive/attempts/api"
require "hive/command_receipt_store"
require "hive/command_dispatch_lifecycle"

module Hive
  module Attempts
    # Shared command-side dispatch and failure interpretation for public Hive
    # commands backed by durable attempts. Consumers resolve the task and
    # provide the intended stage plus worker argv; this module owns the single
    # attach-result policy, including JSON single-document behavior and
    # invocation-scoped internal PR reconciliation emission.
    module CommandDispatch
      MAX_RECONCILIATION_CAPTURE_BYTES = 4 * 1024 * 1024

      # Bounded stdout sink used only when merging this invocation's internal
      # PR reconciliation observation into an attached/replayed JSON document.
      class BoundedCaptureIO
        attr_reader :overflowed

        def initialize(max_bytes: MAX_RECONCILIATION_CAPTURE_BYTES)
          @max_bytes = max_bytes
          @buffer = +""
          @buffer.force_encoding(Encoding::BINARY)
          @overflowed = false
        end

        def write(data)
          chunk = data.to_s.b
          unless @overflowed
            if @buffer.bytesize + chunk.bytesize <= @max_bytes
              @buffer << chunk
            else
              @overflowed = true
            end
          end
          chunk.bytesize
        end

        def flush = self

        def string
          @buffer.dup.force_encoding(Encoding::UTF_8)
        end
      end

      private

      def dispatch_durable
        task = resolve_task
        intended_stage = durable_intended_stage(task)
        attributes = {
          task: task,
          intended_stage: intended_stage,
          argv: durable_worker_argv(task),
          interactive: true
        }
        applicable_pr = internal_pr_reconciliation_applicable?(task, intended_stage: intended_stage)
        capture_io = nil
        if applicable_pr
          require "hive/internal_pr_checkout"
          attributes[:reconcile_mode] = :explicit_reopen
          attributes[:reconcile_deadline] = Hive::InternalPrCheckout.monotonic_deadline(
            project_root: task.respond_to?(:project_root) ? task.project_root : nil
          )
          if @json
            capture_io = BoundedCaptureIO.new
            attributes[:stdout] = capture_io
            attributes[:stderr] = $stderr
          end
        end
        context = defined?(Hive::CommandOperation) && Hive::CommandOperation.current_context
        @command_dispatch_context = context
        if context
          if context.retry_horizon_expires_at.to_s.empty?
            raise Hive::UsageError,
                  "keyed durable dispatch requires an absolute --retry-horizon-expires-at"
          end
          command_dispatch_lifecycle.protect_context!(context, project_root: task.project_root)
          attributes[:request_id] = context.transport_request_id
          Hive::CommandOperation.record_effect_submission(
            kind: "attempt_dispatch",
            identity: {
              "request_id" => context.transport_request_id,
              "target" => @target.to_s, "ordinal" => context.ordinal
            }
          )
        end
        result = (@attempts_api || Hive::Attempts::API.new).dispatch(**attributes)
        interpret_durable_result!(result, captured_stdout: capture_io)
      end

      # Applies the single attach-result policy to a foreground durable
      # dispatch. Commands that need extra admission attributes dispatch
      # themselves and then hand the attach result here.
      def interpret_durable_result!(result, captured_stdout: nil)
        if @json && result.output_status == :expired
          raise Hive::ConcurrentRunError,
                "raw output for successful durable attempt #{result.attempt_id} expired; " \
                "the canonical receipt is still available and the attempt was not rerun"
        end
        emit_foreground_reconciliation!(result, captured_stdout: captured_stdout)
        handle_durable_failure!(result) unless result.exit_status.zero?

        result
      end

      def emit_foreground_reconciliation!(result, captured_stdout:)
        rec = result.respond_to?(:reconciliation) ? result.reconciliation : nil
        if captured_stdout
          raw = captured_stdout.string
          return if raw.empty?

          if !captured_stdout.overflowed
            begin
              doc = JSON.parse(raw)
              if doc.is_a?(Hash)
                if rec
                  doc["reconciliation"] = rec.respond_to?(:to_h) ? rec.to_h : rec
                else
                  # Pure attach: suppress any worker/replayed reconciliation field.
                  doc.delete("reconciliation")
                end
                puts JSON.generate(doc)
                @stdout_written = true
                return
              end
            rescue JSON::ParserError
              nil
            end
          end
          $stdout.write(raw)
          $stdout.flush
          @stdout_written = true
          return
        end

        return if @json || (defined?(@quiet) && @quiet)
        return unless rec

        text = rec.respond_to?(:to_text) ? rec.to_text : rec.to_s
        puts text unless text.empty?
      end

      def internal_pr_reconciliation_applicable?(task, intended_stage:)
        return false unless intended_stage.to_s == "6-review"
        return false unless task && task.respond_to?(:folder) && !task.folder.to_s.empty?

        require "hive/internal_pr_checkout"
        Hive::InternalPrCheckout.applicable?(task)
      end

      def allocate_command_successor!(predecessor_request_id:, intent_id:, intent_version:,
                                      delivery_cycle_id:)
        command_dispatch_lifecycle.allocate_successor!(
          predecessor_request_id: predecessor_request_id, intent_id: intent_id,
          intent_version: intent_version, delivery_cycle_id: delivery_cycle_id
        )
      end

      def command_dispatch_lifecycle
        @command_dispatch_lifecycle ||= Hive::CommandDispatchLifecycle.new(
          repository: @command_dispatch_repository,
          store: @command_receipt_store,
          state_home: defined?(@state_home) && @state_home ? @state_home : Hive::Paths.state_home
        )
      end

      def handle_durable_failure!(result)
        if (reason = BookkeepingReason.from(result))
          if @json && result.stdout_emitted? && !@command_dispatch_context
            warn "hive: #{reason}: durable attempt #{result.attempt_id} requires bookkeeping recovery"
            exit(result.exit_status)
          end
          raise Hive::AttemptExecutionError.new(
            "#{reason}: durable attempt #{result.attempt_id} requires bookkeeping recovery",
            exit_code: result.exit_status, attempt_id: result.attempt_id,
            outcome: result.outcome, reason: reason
          )
        end

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
