require "json"
require "time"
require "timeout"
require "hive/atomic_file"
require "hive/attempts/process_identity"
require "hive/attempts/process_custody"
require "hive/attempts/reconciler"
require "hive/attempts/repository"
require "hive/daemon/finalization_proof"
require "hive/daemon/quiescence_finalizer"
require "hive/daemon/quiescence_process_evidence"
require "hive/daemon/quiescence_result"
require "hive/paths"
require "hive/runtime_control_plane/database"
require "hive/runtime_control_plane/boot_identity"
require "hive/runtime_control_plane/launch_fence"
require "hive/runtime_control_plane/lifecycle_repository"
require "hive/runtime_control_plane/operation_lock"
require "hive/runtime_control_plane/process_registry"

module Hive
  module Daemon
    # Installation-wide quiescence coordinator. It deliberately does not
    # depend on a running daemon: the durable lifecycle, launch registrations,
    # identity checks, attempt receipts, checkpoint and proof are sufficient.
    class Quiescence
      include QuiescenceFinalizer
      include QuiescenceProcessEvidence

      DEFAULT_TIMEOUT_SEC = 600.0
      DRAIN_FRACTION = 0.60
      ESCALATION_FRACTION = 0.25
      FINALIZATION_FRACTION = 0.15
      KILL_FRACTION_OF_ESCALATION = 0.50
      POLL_INTERVAL_SEC = 0.05

      Budget = Data.define(:started_at, :drain_cutoff, :escalation_cutoff, :deadline)

      def initialize(state_home: Hive::Paths.state_home, timeout_sec: DEFAULT_TIMEOUT_SEC,
                     database: nil, lifecycle: nil, registry: nil, capability: nil,
                     process_identity: Hive::Attempts::ProcessIdentity.new,
                     custody: Hive::Attempts::ProcessCustody.detect,
                     attempt_store: nil, reconciler: nil, proof_store: nil,
                     monotonic: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) },
                     clock: -> { Time.now.utc }, sleeper: ->(seconds) { sleep(seconds) },
                     boot_id_reader: nil, signaler: Process.method(:kill),
                     operation_lock_factory: nil, launch_fence_factory: nil)
        @state_home = File.expand_path(state_home)
        @timeout_sec = Float(timeout_sec)
        unless @timeout_sec.positive? && @timeout_sec.finite?
          raise ArgumentError, "quiescence timeout must be positive and finite"
        end
        @database = database || Hive::RuntimeControlPlane::Database.new(
          path: Hive::Paths.runtime_control_plane_path(@state_home)
        )
        @lifecycle = lifecycle || Hive::RuntimeControlPlane::LifecycleRepository.new(
          database: @database, clock: clock
        )
        @process_identity = process_identity
        @custody = custody
        @registry = registry || Hive::RuntimeControlPlane::ProcessRegistry.new(
          database: @database, state_home: @state_home,
          process_identity: process_identity, custody: custody, clock: clock
        )
        @capability = capability || Hive::RuntimeControlPlane::QuiescenceCapability.new(
          database: @database, state_home: @state_home,
          process_identity: process_identity, custody: custody
        )
        @attempt_store = attempt_store
        @reconciler = reconciler
        @proof_store = proof_store || FinalizationProof.new(state_home: @state_home)
        @monotonic = monotonic
        @clock = clock
        @sleeper = sleeper
        @boot_id_reader = boot_id_reader || Hive::RuntimeControlPlane::BootIdentity.method(:current)
        @signaler = signaler
        @operation_lock_factory = operation_lock_factory || lambda do |timeout|
          Hive::RuntimeControlPlane::OperationLock.new(
            state_home: @state_home, timeout_sec: timeout
          )
        end
        @launch_fence_factory = launch_fence_factory || lambda do |timeout|
          Hive::RuntimeControlPlane::LaunchFence.new(
            state_home: @state_home, timeout_sec: timeout
          )
        end
      end

      def call
        @successful_disconnect = false
        started = @monotonic.call
        @budget = Budget.new(
          started_at: started,
          drain_cutoff: started + (@timeout_sec * DRAIN_FRACTION),
          escalation_cutoff: started + (@timeout_sec * (DRAIN_FRACTION + ESCALATION_FRACTION)),
          deadline: started + @timeout_sec
        )
        @database.open!(timeout_sec: remaining(@budget.deadline))
        lock = @operation_lock_factory.call(remaining(@budget.drain_cutoff))
        lock.synchronize { run_under_operation_lock }
      rescue Hive::ConcurrentRunError => error
        nonpaused("controller_busy", details: { "error" => error.message })
      rescue Hive::RuntimeControlPlane::MigrationRequired
        raise
      rescue Hive::RuntimeControlPlane::Error, Hive::Attempts::RepositoryError,
             Sequel::Error, SystemCallError, IOError => error
        reason = @budget && expired?(@budget.drain_cutoff) ? "deadline_exhausted" : "storage_error"
        nonpaused(reason, details: { "error" => "#{error.class}: #{error.message}" })
      ensure
        @database.disconnect unless @successful_disconnect
      end

      private

      def run_under_operation_lock
        state = @lifecycle.current
        @admission_open = state.admission_open?
        pre_settled = false
        entry = nil
        if state.phase == "quiescing"
          rebound = rebind_quiesce_clock_if_needed(state)
          return rebound if rebound.is_a?(QuiescenceResult)
          state = rebound
          settled = settle_launches_and_recheck(state)
          return settled if settled.is_a?(QuiescenceResult)
          state, entry = settled
          pre_settled = true
        else
          entry = @capability.call
        end
        return ownership_refusal(state, entry) unless entry.eligible?
        return nonpaused("deadline_exhausted", lifecycle: state) if expired?(@budget.drain_cutoff)

        if state.phase == "paused"
          identity = installation_id
          proof = @proof_store.verify(lifecycle: state, installation_id: identity)
          return paused_result(state, proof.payload) if proof.valid?

          @database.with_exclusive_writer(
            role: :controller, timeout_sec: remaining(@budget.drain_cutoff)
          ) do |authority|
            state = @lifecycle.return_to_quiescing!(
              generation: state.generation, expected_revision: state.revision,
              authority: authority, now: @clock.call,
              timeout_sec: remaining(@budget.drain_cutoff)
            )
          end
        elsif state.phase == "running"
          @proof_store.remove!
          state = @lifecycle.begin_quiesce!(
            deadline_monotonic: @budget.deadline,
            boot_id: required_boot_id,
            shutdown_grace_sec: @timeout_sec * ESCALATION_FRACTION,
            now: @clock.call, timeout_sec: remaining(@budget.drain_cutoff)
          )
          @admission_open = false
        elsif state.phase != "quiescing"
          return nonpaused("lifecycle_busy", lifecycle: state)
        end

        rebound = rebind_quiesce_clock_if_needed(state)
        return rebound if rebound.is_a?(QuiescenceResult)
        state = rebound
        return nonpaused("deadline_exhausted", lifecycle: state) if expired?(@budget.drain_cutoff)

        unless pre_settled
          settled = settle_launches_and_recheck(state)
          return settled if settled.is_a?(QuiescenceResult)
          state, entry = settled
        end
        post_close_capability = entry
        @proof_inventory = inventory_rows.map { |row| normalize_process(row) }

        drain_until(@budget.drain_cutoff)
        live = live_process_evidence
        signal_processes("TERM", live)
        kill_at = @budget.drain_cutoff +
          ((@budget.escalation_cutoff - @budget.drain_cutoff) * KILL_FRACTION_OF_ESCALATION)
        live = wait_escalation(kill_at: kill_at)
        if live.any?
          return nonpaused(
            "timeout", lifecycle: state, capability: post_close_capability,
            remaining: remaining_without_capability(live)
          )
        end
        return nonpaused("finalization_reserve_exhausted", lifecycle: state) if
          expired?(@budget.escalation_cutoff)

        finalize(state, post_close_capability)
      end

      def settle_launches_and_recheck(state)
        timeout = remaining(@budget.drain_cutoff)
        return nonpaused("deadline_exhausted", lifecycle: state) unless timeout.positive?
        launch_fence = @launch_fence_factory.call(timeout)
        begin
          launch_fence.acquire_exclusive!
        rescue Hive::ConcurrentRunError => error
          return nonpaused(
            "launch_fence_busy", lifecycle: state,
            remaining: unresolved_reservations,
            details: { "error" => error.message }
          )
        end
        begin
          writer_timeout = remaining(@budget.drain_cutoff)
          return nonpaused("deadline_exhausted", lifecycle: state) unless writer_timeout.positive?
          verdict = nil
          begin
            @database.with_exclusive_writer(role: :controller, timeout_sec: writer_timeout) do |authority|
              @registry.settle_preclose_reservations!(
                generation: state.generation, authority: authority,
                timeout_sec: remaining(@budget.drain_cutoff)
              )
              verdict = @capability.call
            end
          rescue Hive::ConcurrentRunError => error
            return nonpaused(
              "writer_drain_timeout", lifecycle: state,
              remaining: [ { "role" => "writer", "unknown_reason" => "writer_fence_busy" } ],
              details: { "error" => error.message }
            )
          end
          return ownership_refusal(state, verdict) unless verdict.eligible?
          [ @lifecycle.current, verdict ]
        ensure
          launch_fence.release!
        end
      end

      def drain_until(cutoff)
        loop do
          break if live_process_evidence.empty? && live_attempt_rows.empty?
          break if expired?(cutoff)
          @sleeper.call([ POLL_INTERVAL_SEC, remaining(cutoff) ].min)
        end
      end

      def wait_escalation(kill_at:)
        kill_sent = false
        live = []
        loop do
          live = live_process_evidence
          return [] if live.empty?
          now = @monotonic.call
          unless kill_sent || now < kill_at
            signal_processes("KILL", live)
            kill_sent = true
          end
          break if now >= @budget.escalation_cutoff
          target = kill_sent ? @budget.escalation_cutoff : [ kill_at, @budget.escalation_cutoff ].min
          @sleeper.call([ POLL_INTERVAL_SEC, target - now ].min)
        end
        live
      end



      def ownership_refusal(state, verdict)
        nonpaused(
          "ownership_unverifiable", lifecycle: state, capability: verdict,
          remaining: verdict.disqualifying_inventory
        )
      end

      def paused_result(state, proof, checkpoint: nil)
        checkpoint ||= proof && proof["checkpoint"]
        LifecycleResultBuilder.quiescence(
          status: "paused", paused: true, reason: nil, phase: state.phase,
          admission_open: false, generation: state.generation,
          lifecycle_revision: state.revision,
          interrupted_attempt_ids: state.interrupted_attempt_ids,
          remaining: [], checkpoint: checkpoint, proof: proof,
          capability: nil, details: {}
        )
      end

      def nonpaused(reason, lifecycle: nil, capability: nil, remaining: [],
                    checkpoint: nil, details: {})
        lifecycle ||= safe_lifecycle
        open = lifecycle ? lifecycle.admission_open? : @admission_open
        LifecycleResultBuilder.quiescence(
          status: "not_paused", paused: false, reason: reason,
          phase: lifecycle&.phase || "unknown", admission_open: open,
          generation: lifecycle&.closed? ? lifecycle.generation : nil,
          lifecycle_revision: lifecycle&.revision,
          interrupted_attempt_ids: lifecycle&.interrupted_attempt_ids || [],
          remaining: Array(remaining), checkpoint: checkpoint, proof: nil,
          capability: capability, details: details
        )
      end

      def safe_lifecycle
        @database.open!(timeout_sec: remaining(@budget.deadline)) if @database.disconnected?
        @lifecycle.current
      rescue StandardError
        nil
      end

      def installation_id = @database.installation_identity.fetch(:installation_id)
      def remaining(cutoff) = [ cutoff - @monotonic.call, 0.0 ].max
      def expired?(cutoff) = @monotonic.call >= cutoff

      def required_boot_id
        @required_boot_id ||= @boot_id_reader.call.to_s.then do |value|
          raise Hive::RuntimeControlPlane::Unavailable.new(
            "host boot identity is unavailable", code: :boot_identity_unavailable,
            action: "repair process identity support and retry"
          ) if value.empty?
          value
        end
      end

      def rebind_quiesce_clock_if_needed(state)
        return state if state.phase != "quiescing" || state.boot_id.to_s == required_boot_id

        timeout = remaining(@budget.drain_cutoff)
        return nonpaused("deadline_exhausted", lifecycle: state) unless timeout.positive?

        @database.with_exclusive_writer(role: :controller, timeout_sec: timeout) do |authority|
          @lifecycle.rebind_quiesce_clock!(
            generation: state.generation, expected_revision: state.revision,
            boot_id: required_boot_id, deadline_monotonic: @budget.deadline,
            shutdown_grace_sec: @timeout_sec * ESCALATION_FRACTION,
            authority: authority, now: @clock.call,
            timeout_sec: remaining(@budget.drain_cutoff)
          )
        end
      rescue Hive::ConcurrentRunError => error
        nonpaused(
          "writer_drain_timeout", lifecycle: state,
          remaining: [ { "role" => "writer", "unknown_reason" => "writer_fence_busy" } ],
          details: { "error" => error.message }
        )
      end
    end

    # Explicit inverse of Quiescence. Admission remains closed while stale
    # process and attempt evidence is reconciled under operation + writer
    # ownership. Managed services are restored only after the generation CAS
    # has reopened admission, and their outcomes are reported independently.
    class Resume
      DEFAULT_TIMEOUT_SEC = 600.0

      def initialize(state_home: Hive::Paths.state_home, timeout_sec: DEFAULT_TIMEOUT_SEC,
                     database: nil, lifecycle: nil, registry: nil,
                     process_identity: Hive::Attempts::ProcessIdentity.new,
                     attempt_store: nil, reconciler: nil, proof_store: nil,
                     service_restorer: nil,
                     monotonic: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) },
                     clock: -> { Time.now.utc }, operation_lock_factory: nil,
                     launch_fence_factory: nil)
        @state_home = File.expand_path(state_home)
        @timeout_sec = Float(timeout_sec)
        unless @timeout_sec.positive? && @timeout_sec.finite?
          raise ArgumentError, "resume timeout must be positive and finite"
        end
        @database = database || Hive::RuntimeControlPlane::Database.new(
          path: Hive::Paths.runtime_control_plane_path(@state_home)
        )
        @lifecycle = lifecycle || Hive::RuntimeControlPlane::LifecycleRepository.new(
          database: @database, clock: clock
        )
        @process_identity = process_identity
        @registry = registry || Hive::RuntimeControlPlane::ProcessRegistry.new(
          database: @database, state_home: @state_home,
          process_identity: process_identity, clock: clock
        )
        @attempt_store = attempt_store
        @reconciler = reconciler
        @proof_store = proof_store || FinalizationProof.new(state_home: @state_home)
        @service_restorer = service_restorer || method(:restore_managed_service)
        @monotonic = monotonic
        @clock = clock
        @operation_lock_factory = operation_lock_factory || lambda do |timeout|
          Hive::RuntimeControlPlane::OperationLock.new(
            state_home: @state_home, timeout_sec: timeout
          )
        end
        @launch_fence_factory = launch_fence_factory || lambda do |timeout|
          Hive::RuntimeControlPlane::LaunchFence.new(
            state_home: @state_home, timeout_sec: timeout
          )
        end
      end

      def call
        @started_at = @monotonic.call
        @deadline = @started_at + @timeout_sec
        @database.open!(timeout_sec: remaining)
        lock = @operation_lock_factory.call(remaining)
        lock.synchronize { run_under_operation_lock }
      rescue Hive::ConcurrentRunError => error
        nonresumed("controller_busy", details: { "error" => error.message })
      rescue Hive::RuntimeControlPlane::MigrationRequired
        raise
      rescue Hive::RuntimeControlPlane::Error, Hive::Attempts::RepositoryError,
             Sequel::Error, SystemCallError, IOError => error
        nonresumed(
          "storage_error", details: { "error" => "#{error.class}: #{error.message}" }
        )
      ensure
        @database.disconnect
      end

      private

      def run_under_operation_lock
        state = @lifecycle.current
        generation = state.generation
        @proof_store.remove!
        if state.phase == "running"
          return restore_services(state)
        end
        unless %w[quiescing paused resuming].include?(state.phase)
          return nonresumed("lifecycle_busy", lifecycle: state)
        end
        return nonresumed("deadline_exhausted", lifecycle: state) unless remaining.positive?

        reopened = nil
        reconciled = []
        unresolved = []
        launch_fence = @launch_fence_factory.call(remaining)
        begin
          launch_fence.acquire_exclusive!
        rescue Hive::ConcurrentRunError => error
          return nonresumed("launch_fence_busy", lifecycle: state,
                            details: { "error" => error.message })
        end
        begin
          @database.with_exclusive_writer(role: :controller, timeout_sec: remaining) do |authority|
            @registry.settle_preclose_reservations!(
              generation: generation, authority: authority, timeout_sec: remaining
            )
            reconciled, unresolved = reconcile_closed_work(
              generation: generation, authority: authority
            )
            unless unresolved.empty?
              return nonresumed(
                "reconciliation_incomplete", lifecycle: @lifecycle.current,
                reconciled_attempt_ids: reconciled, remaining_entries: unresolved
              )
            end
            unless remaining.positive?
              return nonresumed(
                "deadline_exhausted", lifecycle: @lifecycle.current,
                reconciled_attempt_ids: reconciled
              )
            end
            state = @lifecycle.begin_resume!(
              generation: generation, authority: authority, now: @clock.call,
              timeout_sec: remaining
            )
            reopened = @lifecycle.reopen!(
              generation: generation, expected_revision: state.revision,
              authority: authority, now: @clock.call, timeout_sec: remaining
            )
          end
        rescue Hive::ConcurrentRunError => error
          return nonresumed("writer_drain_timeout", lifecycle: state,
                            details: { "error" => error.message })
        ensure
          launch_fence.release!
        end
        restore_services(reopened, reconciled_attempt_ids: reconciled)
      end

      def reconcile_closed_work(generation:, authority:)
        unresolved = []
        active_process_rows.each do |row|
          status = begin
            @process_identity.status(identity_hash(row))
          rescue StandardError => error
            unresolved << normalize_process(row).merge(
              "last_known_state" => "unverifiable",
              "unknown_reason" => "process_identity_probe_failed:#{error.class}"
            )
            next
          end
          if %i[missing mismatched].include?(status)
            if row[:attempt_id] && !@registry.descendant_absence_verified?(row)
              unresolved << normalize_process(row).merge(
                "last_known_state" => status.to_s,
                "unknown_reason" => "descendant_absence_unverified"
              )
            else
              @registry.mark_stopped_by_process!(
                row.fetch(:process_id), authority: authority, reason: "resume_reconciled",
                timeout_sec: remaining
              )
            end
          else
            unresolved << normalize_process(row).merge(
              "last_known_state" => status.to_s,
              "unknown_reason" => (status == :matching ? "owned_process_alive" :
                "process_identity_unverifiable")
            )
          end
        end

        unresolved.concat(active_reservations)
        store = attempt_store_if_needed
        return [ [], unresolved ] unless store

        reconciler = @reconciler || Hive::Attempts::Reconciler.new(
          store: store, process_identity: @process_identity
        )
        reconciled_ids = []
        store.active_attempts.select { |record| record.state == "running" }.each do |record|
          outcome = reconciler.finalize_interruption(
            record, pause_generation: generation, now: @clock.call,
            authority: authority, timeout_sec: remaining
          )
          if %i[interrupted terminal].include?(outcome.classification)
            reconciled_ids << outcome.attempt.attempt_id
          else
            unresolved << attempt_remaining(outcome)
          end
        end
        snapshot = reconciler.reconcile(
          now: @clock.call, authority: authority, timeout_sec: remaining
        )
        snapshot.attempts.each do |outcome|
          if %w[launching running].include?(outcome.attempt.state)
            unresolved << attempt_remaining(outcome)
          elsif %i[lost terminal].include?(outcome.classification)
            reconciled_ids << outcome.attempt.attempt_id
          end
        end
        [ reconciled_ids.uniq.sort, unresolved.uniq ]
      end

      def restore_services(state, reconciled_attempt_ids: [])
        outcomes = service_identities.map do |service_identity|
          timeout = remaining
          if timeout <= 0
            {
              "service_identity" => service_identity, "ok" => false,
              "reason" => "deadline_exhausted"
            }
          else
            outcome = Timeout.timeout(timeout) do
              @service_restorer.call(
                service_identity: service_identity, timeout_sec: timeout
              )
            end
            normalized = stringify(outcome).merge("service_identity" => service_identity)
            mark_service_restored(service_identity) if normalized["ok"] == true
            normalized
          end
        rescue Timeout::Error
          {
            "service_identity" => service_identity, "ok" => false,
            "reason" => "deadline_exhausted"
          }
        rescue StandardError => error
          {
            "service_identity" => service_identity, "ok" => false,
            "reason" => "start_failed", "error" => "#{error.class}: #{error.message}"
          }
        end
        failed = outcomes.reject { |outcome| outcome["ok"] == true }
        if failed.empty?
          LifecycleResultBuilder.resume(
            status: "resumed", resumed: true, reason: nil, phase: state.phase,
            admission_open: true, admission_reopened: true,
            generation: state.generation, lifecycle_revision: state.revision,
            reconciled_attempt_ids: reconciled_attempt_ids,
            remaining: [], services: outcomes, details: {}
          )
        else
          LifecycleResultBuilder.resume(
            status: "partially_resumed", resumed: false,
            reason: failed.any? { |entry| entry["reason"] == "deadline_exhausted" } ?
              "deadline_exhausted" : "service_restore_failed",
            phase: state.phase, admission_open: true, admission_reopened: true,
            generation: state.generation, lifecycle_revision: state.revision,
            reconciled_attempt_ids: reconciled_attempt_ids,
            remaining: [], services: outcomes, details: {}
          )
        end
      end

      def active_process_rows
        @database.read { |db| db[:owned_processes].exclude(state: "stopped").all }
      end

      def active_reservations
        @database.read do |db|
          db[:launch_reservations].where(state: "reserved").all.map do |row|
            stringify(row).merge("unknown_reason" => "launch_reservation_unresolved")
          end
        end
      end

      def service_identities
        @database.read do |db|
          db[:owned_processes].where(state: "stopped", unknown_reason: "quiesced")
            .exclude(service_identity: nil).select_map(:service_identity).uniq.sort
        end
      end

      def mark_service_restored(service_identity)
        @database.transaction(timeout_sec: remaining) do |db|
          db[:owned_processes].where(
            state: "stopped", unknown_reason: "quiesced",
            service_identity: service_identity
          ).update(unknown_reason: "service_restored", updated_at: dump_time(@clock.call))
        end
      end

      def attempt_store_if_needed
        return @attempt_store if @attempt_store
        has_active = @database.read do |db|
          db[:attempts].where(state: %w[launching running]).any?
        end
        return unless has_active

        @attempt_store = Hive::Attempts::Repository.new(
          database: @database, root: Hive::Paths.runtime_payload_root(@state_home),
          create_directories: false
        )
      end

      def restore_managed_service(service_identity:, timeout_sec:)
        installer = case service_identity.to_s
        when "hive-daemon"
          require "hive/commands/daemon/service_installer"
          Hive::Commands::Daemon::ServiceInstaller.new
        when "hive-web"
          require "hive/commands/web/service_installer"
          Hive::Commands::Web::ServiceInstaller.new
        when "hive-bot"
          require "hive/commands/bot/service_installer"
          Hive::Commands::Bot::ServiceInstaller.new
        when "hive-babysitter"
          require "hive/commands/babysit/service_installer"
          Hive::Commands::Babysit::ServiceInstaller.new(hive_home: @state_home)
        end
        return {
          "service_identity" => service_identity, "ok" => false,
          "reason" => "unsupported_service_identity"
        } unless installer

        installer.start!
        { "service_identity" => service_identity, "ok" => true, "reason" => nil }
      end

      def identity_hash(row)
        {
          "pid" => row[:pid], "start_fingerprint" => row[:start_fingerprint],
          "session_id" => row[:session_id], "process_group_id" => row[:process_group_id]
        }
      end

      def normalize_process(row)
        stringify(row).slice(
          "process_id", "reservation_id", "task_id", "attempt_id",
          "service_identity", "origin", "role", "pid", "start_fingerprint",
          "session_id", "process_group_id", "state"
        )
      end

      def attempt_remaining(outcome)
        unless outcome.attempt
          return {
            "attempt_id" => nil, "task_id" => nil, "role" => "attempt",
            "last_known_state" => outcome.classification.to_s,
            "unknown_reason" => outcome.evidence.to_s
          }
        end

        {
          "attempt_id" => outcome.attempt.attempt_id,
          "task_id" => outcome.attempt["task_id"], "role" => "attempt",
          "last_known_state" => outcome.classification.to_s,
          "unknown_reason" => outcome.evidence.to_s
        }
      end

      def nonresumed(reason, lifecycle: nil, reconciled_attempt_ids: [],
                     remaining_entries: [], details: {})
        lifecycle ||= safe_lifecycle
        LifecycleResultBuilder.resume(
          status: "not_resumed", resumed: false, reason: reason,
          phase: lifecycle&.phase || "unknown",
          admission_open: lifecycle&.admission_open? || false,
          admission_reopened: lifecycle&.admission_open? || false,
          generation: lifecycle&.generation, lifecycle_revision: lifecycle&.revision,
          reconciled_attempt_ids: reconciled_attempt_ids,
          remaining: remaining_entries, services: [], details: details
        )
      end

      def safe_lifecycle
        @database.open!(timeout_sec: remaining) if @database.disconnected?
        @lifecycle.current
      rescue StandardError
        nil
      end

      def stringify(value)
        value.to_h.each_with_object({}) { |(key, item), result| result[key.to_s] = item }
      end

      def dump_time(value) = Hive::RuntimeControlPlane::Codec.dump_time(value)
      def remaining = [ @deadline - @monotonic.call, 0.0 ].max
    end
  end
end
