require "shellwords"
require "hive/daemon/recovery_coordinator"
require "hive/attempts/api"

module Hive
  module Recovery
    # A caller attaches as a reader after ordinary transactional admission.
    # Neither caller loss nor a concurrent daemon grants a second launch.
    class ManualRetry
      class Sink
        def write(bytes) = bytes.bytesize
        def flush = self
      end

      def initialize(coordinator:, state_home: Hive::Paths.state_home,
                     repository: nil, store: nil, attempts: nil, client: nil)
        @coordinator = coordinator
        @state_home = state_home
        @repository = repository
        @store = store
        @attempts = attempts
        @client = client
      end

      def call(row:, observation_token:, now: Time.now.utc)
        row = API.observation(row)
        receipt = @coordinator.prepare_manual(row: row, observation_token: observation_token, now: now)
        request = repository.fetch(receipt.request_id) if receipt.request_id
        return guidance(receipt, row) unless request
        if receipt.phase == "terminal"
          @coordinator.repair_failed_terminal_marker(request)
          return receipt
        end
        if receipt.phase == "dispatched"
          record = attempts.fetch(receipt.attempt_id) if receipt.attempt_id
          return unavailable(receipt, row, "attempt_observation_unavailable") unless record
          return unavailable(receipt, row, "attempt_identity_conflict") unless @coordinator.manual_attempt_matches?(request, record)
          # Record validation admits only live or final states.
          return record.final? ? finish(request, record) : attach(request, record.attempt_id, row)
        end
        return guidance(receipt, row) unless receipt.phase == "cleared" && receipt.status == "queued"

        # Recovery takes task leases and records a newer source observation.
        # Admission must observe after those writes rather than reuse the
        # action's entry timestamp as a superseded source observation.
        result = dispatch(request, now: [ now, Time.now.utc ].max)
        case result.status
        when :accepted, :existing_live
          @coordinator.mark_dispatched(request, attempt_id: result.attempt.attempt_id, now: now)
          attach(request, result.attempt.attempt_id, row)
        when :terminal_replay
          finish(request, result.attempt)
        else # :deferred or :no_route, the dispatcher's only other outcomes
          if result.reason == "attempt_lost" && result.attempt&.state == "lost" &&
              result.attempt["request_id"] == request.request_id &&
              @coordinator.manual_attempt_matches?(request, result.attempt)
            return finish(request, result.attempt)
          end
          observed = @coordinator.observe_admission_result(request: request, result: result, now: now)
          @coordinator.defer_dispatch_failure(request, now: now) if result.status == :deferred
          base = observed || receipt
          guidance(base.with(status: result.status == :no_route ? "unavailable" : "blocked",
            owner: result.status == :no_route ? "provider" : "operator", reason: result.reason), row)
        end
      rescue Hive::Error, SystemCallError, IOError => error
        @coordinator.defer_dispatch_failure(request, now: now) if request
        base = receipt || Hive::Daemon::RecoveryCoordinator::Receipt.from_h({})
        unavailable(base.with(remediation: "#{error.class}: #{error.message}"), row, "launch_unavailable")
      end

      private

      def repository
        @repository ||= Hive::RuntimeControlPlane::DispatchRepository.open_default(state_home: @state_home)
      end

      def attempts
        @attempts ||= Hive::Attempts::API.new(store: @store, state_home: @state_home)
      end

      def dispatch(request, now:)
        # A new keyed caller can consume an older request. Correlate the
        # effect with that identity without rebinding the original request to
        # the new command's transport identity.
        if defined?(Hive::CommandOperation)
          Hive::CommandOperation.record_effect_submission(kind: "dispatch_request", identity: {
            "request_id" => request.request_id, "project" => request.project, "slug" => request.slug
          })
        end
        previous = Thread.current[:hive_command_operation_context]
        begin
          Thread.current[:hive_command_operation_context] = nil
          attempts.dispatch_request(request, interactive: false, now: now)
        ensure
          Thread.current[:hive_command_operation_context] = previous
        end
      end

      def attach(request, attempt_id, row)
        # Inner stage envelopes belong to the attempt log. Act emits one final
        # envelope of its own, including when a keyed operation captures stdout.
        # Attachment returns on a terminal or lost record, or when the caller
        # detaches; a non-final record afterwards means the caller detached.
        (@client || attempts).attach(attempt_id, stdout: Sink.new, stderr: Sink.new)
        record = attempts.fetch(attempt_id)
        return finish(request, record) if record&.final?
        guidance(@coordinator.receipt_for_request(repository.fetch(request.request_id)).with(
          reason: "caller_detached", owner: "agent"), row)
      end

      def finish(request, record)
        terminal = record.receipt || {}
        ended_at = terminal["ended_at"] || record["ended_at"]
        receipt = @coordinator.mark_dispatched(request, attempt_id: record.attempt_id,
          terminal: true, outcome: record.state == "lost" ? "lost" : record.outcome,
          now: ended_at ? Time.iso8601(ended_at) : Time.now.utc)
        @coordinator.repair_failed_terminal_marker(request)
        receipt
      end

      def unavailable(receipt, row, reason)
        guidance(receipt.with(status: "unavailable", owner: "hive", reason: reason), row)
      end

      def guidance(receipt, row)
        return receipt if receipt.status == "terminal"
        command = if receipt.status == "running" || receipt.reason == "existing_live"
          Shellwords.join([ "hive", "task", API.row_value(row, :slug), "--project", API.row_value(row, :project), "--json" ])
        else
          "hive status --operational --json"
        end
        receipt = receipt.with(status: "blocked", owner: "operator", reason: receipt.reason || "project_dispatch_disabled") if
          %w[queued cooldown].include?(receipt.status)
        receipt.with(remediation: [ receipt.remediation, command ].compact.uniq.join("; "))
      end
    end
  end
end
