require "json"
require "time"
require "hive/atomic_file"
require "hive/attempts/process_identity"
require "hive/attempts/process_custody"
require "hive/attempts/reconciler"
require "hive/attempts/repository"
require "hive/paths"
require "hive/runtime_control_plane/database"
require "hive/runtime_control_plane/boot_identity"
require "hive/runtime_control_plane/launch_fence"
require "hive/runtime_control_plane/lifecycle_repository"
require "hive/runtime_control_plane/operation_lock"
require "hive/runtime_control_plane/process_registry"

module Hive
  module Daemon
    QuiescenceResult = Data.define(
      :status, :paused, :reason, :phase, :admission_open, :generation,
      :lifecycle_revision, :interrupted_attempt_ids, :remaining,
      :checkpoint, :proof, :capability, :details
    ) do
      def to_h
        {
          "status" => status, "paused" => paused, "reason" => reason,
          "phase" => phase, "admission_open" => admission_open,
          "generation" => generation, "lifecycle_revision" => lifecycle_revision,
          "interrupted_attempt_ids" => interrupted_attempt_ids,
          "remaining" => remaining, "checkpoint" => checkpoint,
          "proof" => proof, "capability" => capability&.to_h,
          "details" => details
        }
      end
    end

    ProofVerdict = Data.define(:valid, :reason, :payload) do
      def valid? = valid == true
    end

    # Crash-durable acknowledgement written only after SQLite has completed a
    # checked FULL checkpoint and closed its connection. The database row is a
    # paused candidate; status may expose it as paused only while every binding
    # in this file still matches.
    class FinalizationProof
      SCHEMA = "hive-runtime-quiescence-proof".freeze
      SCHEMA_VERSION = 1
      MAX_BYTES = 16 * 1024 * 1024
      KEYS = %w[
        schema schema_version installation_id generation lifecycle_revision
        mutation_sequence interrupted_attempt_ids inventory checkpoint published_at
      ].freeze

      attr_reader :path

      def initialize(state_home: Hive::Paths.state_home, writer: Hive::AtomicFile,
                     json: JSON)
        @path = Hive::Paths.runtime_quiescence_proof_path(File.expand_path(state_home))
        @writer = writer
        @json = json
      end

      def publish!(lifecycle:, installation_id:, checkpoint:, interrupted_attempt_ids:,
                   inventory:, published_at: Time.now.utc)
        payload = {
          "schema" => SCHEMA, "schema_version" => SCHEMA_VERSION,
          "installation_id" => installation_id.to_s,
          "generation" => Integer(lifecycle.generation),
          "lifecycle_revision" => Integer(lifecycle.revision),
          "mutation_sequence" => Integer(lifecycle.mutation_sequence),
          "interrupted_attempt_ids" => Array(interrupted_attempt_ids).map(&:to_s).uniq.sort,
          "inventory" => Array(inventory).map { |entry| stringify(entry) },
          "checkpoint" => stringify(checkpoint),
          "published_at" => published_at.utc.iso8601(6)
        }
        bytes = "#{@json.generate(payload)}\n"
        raise IOError, "runtime quiescence proof exceeds its size bound" if bytes.bytesize > MAX_BYTES
        @writer.write(path, bytes, mode: 0o600, fsync: true)
        @writer.fsync_directory(File.dirname(path))
        payload.freeze
      rescue StandardError
        begin
          File.delete(path) if File.file?(path) && !File.symlink?(path)
          @writer.fsync_directory(File.dirname(path)) if File.directory?(File.dirname(path))
        rescue StandardError
          nil
        end
        raise
      end

      def verify(lifecycle:, installation_id:)
        payload = read
        return payload if payload.is_a?(ProofVerdict)
        return invalid("installation_mismatch", payload) unless
          payload.fetch("installation_id") == installation_id.to_s
        return invalid("generation_mismatch", payload) unless
          payload.fetch("generation") == lifecycle.generation
        return invalid("revision_mismatch", payload) unless
          payload.fetch("lifecycle_revision") == lifecycle.revision
        return invalid("mutation_sequence_mismatch", payload) unless
          payload.fetch("mutation_sequence") == lifecycle.mutation_sequence
        return invalid("interrupted_attempts_mismatch", payload) unless
          payload.fetch("interrupted_attempt_ids").sort == lifecycle.interrupted_attempt_ids.sort
        return invalid("lifecycle_not_paused", payload) unless lifecycle.phase == "paused"

        ProofVerdict.new(valid: true, reason: nil, payload: payload)
      end

      def read
        return invalid("proof_missing") unless File.exist?(path) || File.symlink?(path)
        status = File.lstat(path)
        unless status.file? && !status.symlink? && status.uid == Process.uid &&
               status.nlink == 1 && (status.mode & 0o077).zero? && status.size <= MAX_BYTES
          return invalid("proof_custody_invalid")
        end
        payload = @json.parse(File.binread(path))
        validate!(payload)
        payload
      rescue JSON::ParserError, KeyError, ArgumentError, TypeError,
             SystemCallError, IOError
        invalid("proof_invalid")
      end

      def remove!
        return false unless File.exist?(path) || File.symlink?(path)
        status = File.lstat(path)
        unless status.file? && !status.symlink? && status.uid == Process.uid && status.nlink == 1
          raise Hive::RuntimeControlPlane::IntegrityError.new(
            "runtime quiescence proof has unsafe custody", code: :proof_custody_invalid,
            action: Hive::RuntimeControlPlane::Database::BACKUP_ACTION
          )
        end
        File.delete(path)
        @writer.fsync_directory(File.dirname(path))
        true
      end

      private

      def validate!(payload)
        raise ArgumentError unless payload.is_a?(Hash) && payload.keys.sort == KEYS.sort
        raise ArgumentError unless payload.fetch("schema") == SCHEMA
        raise ArgumentError unless payload.fetch("schema_version") == SCHEMA_VERSION
        %w[generation lifecycle_revision mutation_sequence].each do |key|
          raise ArgumentError unless payload.fetch(key).is_a?(Integer) && payload.fetch(key) >= 0
        end
        raise ArgumentError unless payload.fetch("installation_id").is_a?(String) &&
          !payload.fetch("installation_id").empty?
        interrupted = payload.fetch("interrupted_attempt_ids")
        raise ArgumentError unless interrupted.is_a?(Array) &&
          interrupted.all? { |attempt_id| attempt_id.is_a?(String) && !attempt_id.empty? }
        inventory = payload.fetch("inventory")
        raise ArgumentError unless inventory.is_a?(Array) && inventory.all? { |item| item.is_a?(Hash) }
        checkpoint = payload.fetch("checkpoint")
        raise ArgumentError unless checkpoint.is_a?(Hash) && checkpoint["complete"] == true
        %w[busy log_frames checkpointed_frames].each do |key|
          raise ArgumentError unless checkpoint[key].is_a?(Integer) && checkpoint[key] >= 0
        end
        raise ArgumentError unless checkpoint["busy"].zero? &&
          checkpoint["checkpointed_frames"] >= checkpoint["log_frames"]
        Time.iso8601(payload.fetch("published_at"))
        true
      end

      def invalid(reason, payload = nil)
        ProofVerdict.new(valid: false, reason: reason, payload: payload)
      end

      def stringify(value)
        case value
        when Hash
          value.each_with_object({}) { |(key, item), result| result[key.to_s] = stringify(item) }
        when Array then value.map { |item| stringify(item) }
        else value
        end
      end
    end

    # Installation-wide quiescence coordinator. It deliberately does not
    # depend on a running daemon: the durable lifecycle, launch registrations,
    # identity checks, attempt receipts, checkpoint and proof are sufficient.
    class Quiescence
      DEFAULT_TIMEOUT_SEC = 600.0
      DRAIN_FRACTION = 0.60
      ESCALATION_FRACTION = 0.25
      FINALIZATION_FRACTION = 0.15
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
        @database.open!
        started = @monotonic.call
        @budget = Budget.new(
          started_at: started,
          drain_cutoff: started + (@timeout_sec * DRAIN_FRACTION),
          escalation_cutoff: started + (@timeout_sec * (DRAIN_FRACTION + ESCALATION_FRACTION)),
          deadline: started + @timeout_sec
        )
        lock = @operation_lock_factory.call(remaining(@budget.drain_cutoff))
        lock.synchronize { run_under_operation_lock }
      rescue Hive::ConcurrentRunError => error
        nonpaused("controller_busy", details: { "error" => error.message })
      rescue Hive::RuntimeControlPlane::Error, Sequel::Error, SystemCallError, IOError => error
        reason = @budget && expired?(@budget.drain_cutoff) ? "deadline_exhausted" : "storage_error"
        nonpaused(reason, details: { "error" => "#{error.class}: #{error.message}" })
      ensure
        @database.disconnect unless @successful_disconnect
      end

      private

      def run_under_operation_lock
        state = @lifecycle.current
        entry = @capability.call
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
        elsif state.phase != "quiescing"
          return nonpaused("lifecycle_busy", lifecycle: state)
        end

        return nonpaused("clock_identity_changed", lifecycle: state) unless
          state.boot_id.to_s == required_boot_id
        return nonpaused("deadline_exhausted", lifecycle: state) if expired?(@budget.drain_cutoff)

        settled = settle_launches_and_recheck(state)
        return settled if settled.is_a?(QuiescenceResult)
        state, post_close_capability = settled
        @proof_inventory = inventory_rows.map { |row| normalize_process(row) }

        drain_until(@budget.drain_cutoff)
        live = live_process_evidence
        signal_processes("TERM", live)
        kill_at = @budget.drain_cutoff +
          ((@budget.escalation_cutoff - @budget.drain_cutoff) * 0.50)
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
        launch_fence.acquire_exclusive!
        begin
          writer_timeout = remaining(@budget.drain_cutoff)
          return nonpaused("deadline_exhausted", lifecycle: state) unless writer_timeout.positive?
          verdict = nil
          @database.with_exclusive_writer(role: :controller, timeout_sec: writer_timeout) do |authority|
            @registry.settle_preclose_reservations!(
              generation: state.generation, authority: authority,
              timeout_sec: remaining(@budget.drain_cutoff)
            )
            verdict = @capability.call
          end
          return ownership_refusal(state, verdict) unless verdict.eligible?
          [ @lifecycle.current, verdict ]
        ensure
          launch_fence.release!
        end
      rescue Hive::ConcurrentRunError => error
        nonpaused(
          "launch_fence_busy", lifecycle: state,
          remaining: unresolved_reservations,
          details: { "error" => error.message }
        )
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
        live = live_process_evidence
        signal_processes("KILL", live) unless kill_sent
        live_process_evidence
      end

      def finalize(state, capability)
        writer_timeout = remaining(@budget.escalation_cutoff)
        return nonpaused("writer_drain_timeout", lifecycle: state) unless writer_timeout.positive?

        result = nil
        @database.with_exclusive_writer(role: :controller, timeout_sec: writer_timeout) do |authority|
          interrupted = finalize_stopped_processes_and_attempts(
            generation: state.generation, authority: authority
          )
          remaining_entries = final_remaining
          unless remaining_entries.empty?
            result = nonpaused(
              "work_remaining", lifecycle: @lifecycle.current, capability: capability,
              remaining: remaining_entries
            )
            next
          end
          if expired?(@budget.deadline)
            result = nonpaused("deadline_exhausted", lifecycle: @lifecycle.current)
            next
          end

          current = @lifecycle.current
          candidate = @lifecycle.mark_paused!(
            generation: current.generation, expected_revision: current.revision,
            interrupted_attempt_ids: interrupted, authority: authority, now: @clock.call,
            timeout_sec: remaining(@budget.deadline)
          )
          checkpoint = checkpoint_candidate(candidate, authority: authority)
          if checkpoint.is_a?(QuiescenceResult)
            result = checkpoint
            next
          end
          identity = installation_id
          @database.disconnect
          @successful_disconnect = true
          begin
            proof = @proof_store.publish!(
              lifecycle: candidate, installation_id: identity, checkpoint: checkpoint,
              interrupted_attempt_ids: interrupted, inventory: proof_inventory,
              published_at: @clock.call
            )
            if expired?(@budget.deadline)
              @proof_store.remove!
              @successful_disconnect = false
              @database.open!
              restored = @lifecycle.return_to_quiescing!(
                generation: candidate.generation, expected_revision: candidate.revision,
                authority: authority, now: @clock.call,
                timeout_sec: remaining(@budget.deadline)
              )
              result = nonpaused(
                "deadline_exhausted", lifecycle: restored, checkpoint: checkpoint
              )
            else
              result = paused_result(candidate, proof, checkpoint: checkpoint)
            end
          rescue StandardError => error
            @successful_disconnect = false
            @database.open!
            begin
              @proof_store.remove!
            rescue StandardError
              nil
            end
            restored = @lifecycle.return_to_quiescing!(
              generation: candidate.generation, expected_revision: candidate.revision,
              authority: authority, now: @clock.call,
              timeout_sec: remaining(@budget.deadline)
            )
            result = nonpaused(
              "proof_publication_failed", lifecycle: restored,
              checkpoint: checkpoint,
              details: { "error" => "#{error.class}: #{error.message}" }
            )
          end
        end
        result
      rescue Hive::ConcurrentRunError => error
        nonpaused(
          "writer_drain_timeout", lifecycle: state,
          remaining: [ { "role" => "writer", "unknown_reason" => "writer_fence_busy" } ],
          details: { "error" => error.message }
        )
      end

      def checkpoint_candidate(candidate, authority:)
        timeout = remaining(@budget.deadline)
        if timeout <= 0
          restored = rollback_candidate(candidate, authority)
          return nonpaused("deadline_exhausted", lifecycle: restored)
        end
        checkpoint = @database.checkpoint!(timeout_sec: timeout)
        unless checkpoint.fetch(:complete) && checkpoint.fetch(:busy).zero? &&
               checkpoint.fetch(:checkpointed_frames) >= checkpoint.fetch(:log_frames)
          restored = rollback_candidate(candidate, authority)
          return nonpaused(
            "checkpoint_busy", lifecycle: restored, checkpoint: checkpoint
          )
        end
        if expired?(@budget.deadline)
          restored = rollback_candidate(candidate, authority)
          return nonpaused(
            "deadline_exhausted", lifecycle: restored, checkpoint: checkpoint
          )
        end
        checkpoint
      rescue StandardError => error
        restored = rollback_candidate(candidate, authority)
        nonpaused(
          "checkpoint_error", lifecycle: restored,
          details: { "error" => "#{error.class}: #{error.message}" }
        )
      end

      def rollback_candidate(candidate, authority)
        @lifecycle.return_to_quiescing!(
          generation: candidate.generation, expected_revision: candidate.revision,
          authority: authority, now: @clock.call,
          timeout_sec: remaining(@budget.deadline)
        )
      end

      def finalize_stopped_processes_and_attempts(generation:, authority:)
        inventory_rows.each do |row|
          status = @process_identity.status(identity_hash(row))
          next unless %i[missing mismatched].include?(status)
          @registry.mark_stopped_by_process!(
            row.fetch(:process_id), authority: authority, reason: "quiesced",
            timeout_sec: remaining(@budget.deadline)
          )
        end

        interrupted = durable_interrupted_attempts(generation)
        store = attempt_store_if_needed
        return interrupted unless store
        reconciler = @reconciler || Hive::Attempts::Reconciler.new(
          store: store, process_identity: @process_identity
        )
        store.active_attempts.select { |record| record.state == "running" }.each do |record|
          outcome = reconciler.finalize_interruption(
            record, pause_generation: generation, now: @clock.call, authority: authority,
            timeout_sec: remaining(@budget.deadline)
          )
          interrupted << outcome.attempt.attempt_id if outcome.classification == :interrupted
        end
        interrupted.uniq.sort
      end

      def final_remaining
        unresolved = remaining_without_capability(live_process_evidence)
        final_capability = @capability.call
        capability_entries = if final_capability.eligible?
          []
        else
          final_capability.disqualifying_inventory.map do |entry|
            entry.merge("unknown_reason" => final_capability.reason)
          end
        end
        unresolved + capability_entries
      end

      def remaining_without_capability(live)
        processes = live.map { |entry| remaining_process(entry) }
        attempts = live_attempt_rows.map do |row|
          {
            "attempt_id" => row.fetch(:attempt_id), "task_id" => row[:task_id],
            "role" => "attempt", "last_known_state" => row.fetch(:state),
            "pid" => nil, "unknown_reason" => "attempt_not_reconciled"
          }
        end
        processes + attempts + unresolved_reservations
      end

      def signal_processes(signal, live)
        identities = live.flat_map do |entry|
          row = entry.fetch(:row)
          [ identity_hash(row), *entry.fetch(:descendants, []) ]
        end
        identities.uniq { |identity| [ identity["pid"], identity["start_fingerprint"] ] }
          .each do |identity|
            next if identity.fetch("pid") == Process.pid
            next unless @process_identity.status(identity) == :matching
          @signaler.call(signal, identity.fetch("pid"))
          rescue Errno::ESRCH
            next
          rescue Errno::EPERM
            signal_failures[[ identity["pid"], identity["start_fingerprint"] ]] =
              "signal_permission_denied"
            next
          end
      end

      def custody_member_evidence(row)
        return [ [], nil ] unless
          row[:custody_mode] == "delegated_cgroup_v2" && row[:custody_path]
        identities = @custody.members(row.fetch(:custody_path)).filter_map do |pid|
          next if pid == Process.pid || pid == row[:pid]
          @process_identity.capture(pid)&.to_h
        end
        cache = descendant_cache(row)
        identities.each do |identity|
          cache[[ identity.fetch("pid"), identity.fetch("start_fingerprint") ]] = identity
        end
        live = cache.values.reject do |identity|
          %i[missing mismatched].include?(@process_identity.status(identity))
        end
        [ live, nil ]
      rescue Hive::Error, SystemCallError, IOError, ArgumentError, TypeError => error
        cached = descendant_cache(row).values.reject do |identity|
          %i[missing mismatched].include?(@process_identity.status(identity))
        end
        [ cached, "custody_inventory_unavailable:#{error.class}" ]
      end

      def live_process_evidence
        inventory_rows.filter_map do |row|
          status = @process_identity.status(identity_hash(row))
          descendants, custody_error = custody_member_evidence(row)
          root_absent = %i[missing mismatched].include?(status)
          next if root_absent && descendants.empty? && custody_error.nil?
          status = :unverifiable if custody_error
          { row: row, status: status, descendants: descendants,
            custody_error: custody_error }
        end
      end

      def descendant_cache(row)
        @descendant_identities ||= {}
        @descendant_identities[row.fetch(:process_id)] ||= {}
      end

      def proof_inventory
        descendants = (@descendant_identities || {}).flat_map do |process_id, entries|
          entries.values.map do |identity|
            identity.merge(
              "process_id" => process_id, "role" => "descendant",
              "origin" => "delegated_cgroup_v2"
            )
          end
        end
        Array(@proof_inventory) + descendants
      end

      def inventory_rows = @registry.active_rows

      def live_attempt_rows
        @database.read do |db|
          db[:attempts].where(state: %w[launching running]).order(:attempt_id).all
        end
      end

      def unresolved_reservations
        @database.read do |db|
          db[:launch_reservations].where(state: "reserved").order(:reservation_id).all.map do |row|
            {
              "reservation_id" => row.fetch(:reservation_id),
              "attempt_id" => row[:attempt_id], "task_id" => row[:task_id],
              "origin" => row.fetch(:origin), "role" => row.fetch(:role),
              "pid" => row[:owner_pid], "last_known_state" => row.fetch(:state)
            }
          end
        end
      rescue Hive::RuntimeControlPlane::Error, Sequel::Error
        []
      end

      def attempt_store_if_needed
        return @attempt_store if @attempt_store
        return nil if live_attempt_rows.empty?

        @attempt_store = Hive::Attempts::Repository.new(
          database: @database, root: Hive::Paths.runtime_payload_root(@state_home),
          create_directories: false
        )
      end

      def remaining_process(entry)
        normalize_process(entry.fetch(:row)).merge(
          "last_known_state" => entry.fetch(:status).to_s,
          "unknown_reason" => entry[:custody_error] ||
            signal_failures[[ entry.dig(:row, :pid), entry.dig(:row, :start_fingerprint) ]] ||
            (entry.fetch(:status) == :unverifiable ? "process_identity_unverifiable" : nil),
          "descendants" => entry.fetch(:descendants, [])
        )
      end

      def durable_interrupted_attempts(generation)
        @database.read do |db|
          db[:attempts].where(state: "terminal", outcome: "interrupted").all.filter_map do |row|
            receipt = Hive::RuntimeControlPlane::Codec.load_json(
              row.fetch(:terminal_receipt_json)
            )
            row.fetch(:attempt_id) if receipt["pause_generation"] == Integer(generation)
          rescue Hive::RuntimeControlPlane::CodecError, KeyError, TypeError
            nil
          end
        end
      end

      def signal_failures = @signal_failures ||= {}

      def normalize_process(row)
        {
          "process_id" => row[:process_id], "reservation_id" => row[:reservation_id],
          "task_id" => row[:task_id], "attempt_id" => row[:attempt_id],
          "service_identity" => row[:service_identity], "origin" => row[:origin],
          "role" => row[:role], "pid" => row[:pid],
          "start_fingerprint" => row[:start_fingerprint],
          "session_id" => row[:session_id], "process_group_id" => row[:process_group_id],
          "custody_mode" => row[:custody_mode], "custody_path" => row[:custody_path]
        }
      end

      def identity_hash(row)
        {
          "pid" => row[:pid], "start_fingerprint" => row[:start_fingerprint],
          "session_id" => row[:session_id], "process_group_id" => row[:process_group_id]
        }
      end

      def ownership_refusal(state, verdict)
        nonpaused(
          "ownership_unverifiable", lifecycle: state, capability: verdict,
          remaining: verdict.disqualifying_inventory
        )
      end

      def paused_result(state, proof, checkpoint: nil)
        checkpoint ||= proof && proof["checkpoint"]
        QuiescenceResult.new(
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
        open = lifecycle ? lifecycle.admission_open? : false
        QuiescenceResult.new(
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
        @database.open! if @database.disconnected?
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
    end
  end
end
