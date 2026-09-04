require "digest"
require "time"
require "hive/agent_limit"
require "hive/attempts/dirty_state_capture"
require "hive/runtime_control_plane"
require "hive/stringify_keys"
require "hive/task_resolver"

module Hive
  module Attempts
    # Transactional policy for cleanup after an irreversible lost lease. The
    # attempt row remains the only recovery authority; its independent revision
    # never rewrites the immutable execution record.
    class LostOutcomeTransition
      PHASES = %w[pending ready complete].freeze
      FINAL_PHASES = %w[complete].freeze
      SAFE_CLEANUPS = %w[absent terminated no_worker].freeze
      CLEANUPS = (SAFE_CLEANUPS + %w[identity_mismatch identity_changed still_alive]).freeze

      def initialize(store:)
        @store = store
      end

      def ensure_for(attempt, now: Time.now.utc)
        validate_attempt!(attempt)
        @store.database.transaction do |db|
          dataset = db[:attempts].where(attempt_id: attempt.attempt_id, state: "lost")
          row = dataset.first
          raise RepositoryError, "lost recovery attempt is missing" unless row
          next parse(db, row) if row[:lost_recovery_phase]

          changed = dataset.where(
            lost_recovery_phase: nil, lost_recovery_revision: nil
          ).update(
            lost_recovery_phase: "pending", lost_recovery_revision: 0,
            lost_recovery_updated_at: now.utc.iso8601(6)
          )
          row = dataset.first
          raise RepositoryError, "lost recovery changed concurrently" unless changed == 1 || row[:lost_recovery_phase]
          parse(db, row)
        end
      rescue Sequel::Error, RuntimeControlPlane::Error => error
        raise RepositoryError, "lost outcome could not be created: #{error.message}"
      end

      def fetch(attempt_id)
        @store.database.read do |db|
          row = db[:attempts].where(attempt_id: attempt_id.to_s, state: "lost").first
          row && row[:lost_recovery_phase] && parse(db, row)
        end
      rescue Sequel::Error, RuntimeControlPlane::Error => error
        raise RepositoryError, "lost outcome #{attempt_id} is unreadable: #{error.message}"
      end

      def update(attempt, now: Time.now.utc, **changes)
        validate_attempt!(attempt)
        requested = stringify(changes)
        unless (requested.keys - %w[phase cleanup request_id capture_references]).empty?
          raise RepositoryError, "lost recovery update is invalid"
        end
        @store.database.transaction do |db|
          row = db[:attempts].where(attempt_id: attempt.attempt_id, state: "lost").first
          current = row && row[:lost_recovery_phase] && parse(db, row)
          raise RepositoryError, "lost recovery is missing" unless current
          validate_identity!(current, attempt)
          replacement = current.merge(requested.except("capture_references")).merge(
            "updated_at" => now.utc.iso8601(6)
          )
          validate_transition!(current, replacement, attempt)
          persist_capture_references(
            db, attempt, requested.fetch("capture_references", []), now: now
          ) if requested.key?("capture_references")
          changed = db[:attempts].where(
            attempt_id: attempt.attempt_id,
            lost_recovery_revision: row.fetch(:lost_recovery_revision),
            lost_recovery_phase: row.fetch(:lost_recovery_phase)
          ).update(
            lost_recovery_phase: replacement.fetch("phase"),
            lost_recovery_cleanup: replacement["cleanup"],
            lost_recovery_request_id: replacement["request_id"],
            lost_recovery_revision: row.fetch(:lost_recovery_revision) + 1,
            lost_recovery_updated_at: replacement.fetch("updated_at")
          )
          unless changed == 1
            fresh = db[:attempts].where(attempt_id: attempt.attempt_id).first
            return parse(db, fresh) if fresh && equivalent_or_later?(parse(db, fresh), replacement)
            raise RepositoryError, "lost recovery changed concurrently"
          end
          parse(db, db[:attempts].where(attempt_id: attempt.attempt_id).first)
        end
      rescue Sequel::Error, RuntimeControlPlane::Error => error
        raise RepositoryError, "lost outcome could not be updated: #{error.message}"
      end

      private

      def recovery_request_id(attempt)
        ::Digest::SHA256.hexdigest(
          [ "hive-attempt-loss-recovery-v1", attempt.attempt_id,
            attempt.task_generation, attempt["loss"]["at"] ].join("\0")
        )[0, 32]
      end

      public :recovery_request_id

      def parse(db, row)
        record = RuntimeControlPlane::Codec.load_json(row.fetch(:record_json))
        unless Digest::SHA256.hexdigest(row.fetch(:record_json)) == row.fetch(:record_digest)
          raise RepositoryError, "lost recovery execution record digest is invalid"
        end
        data = {
          "schema" => "hive-attempt-lost-recovery", "schema_version" => 1,
          "attempt_id" => row.fetch(:attempt_id),
          "task_generation" => row.fetch(:task_generation),
          "project" => row.fetch(:project_name), "task_slug" => row.fetch(:task_slug),
          "phase" => row.fetch(:lost_recovery_phase),
          "cleanup" => row[:lost_recovery_cleanup],
          "request_id" => row[:lost_recovery_request_id],
          "revision" => row.fetch(:lost_recovery_revision),
          "updated_at" => row.fetch(:lost_recovery_updated_at),
          "capture_references" => capture_references(db, row.fetch(:attempt_id))
        }
        unless record.fetch("attempt_id") == data.fetch("attempt_id") &&
               record.fetch("task_generation") == data.fetch("task_generation")
          raise RepositoryError, "lost recovery identity disagrees with its execution record"
        end
        validate!(data)
        data.freeze
      end

      def capture_references(db, attempt_id)
        db[:payload_references].where(attempt_id: attempt_id, kind: "lost_capture", state: "open")
          .order(:payload_id).filter_map do |row|
            path = File.join(@store.root, row.fetch(:relative_path))
            OutputReference.build(path, root: @store.root)
          rescue InvalidOutputReference, SystemCallError, IOError
            nil
          end.freeze
      end

      def persist_capture_references(db, attempt, references, now:)
        Array(references).each_with_index do |reference, index|
          value = Hive::StringifyKeys.call(reference)
          OutputReference.validate_shape!(value)
          relative = value.fetch("path")
          prefix = File.join("open", attempt.attempt_id, "dirty-state") + File::SEPARATOR
          unless relative.start_with?(prefix)
            raise RepositoryError, "lost recovery capture reference is outside its attempt"
          end
          payload_id = "lost-capture:#{attempt.attempt_id}:#{index}"
          existing = db[:payload_references].where(payload_id: payload_id).first
          if existing
            unless existing.fetch(:attempt_id) == attempt.attempt_id &&
                   existing.fetch(:kind) == "lost_capture" &&
                   existing.fetch(:relative_path) == relative && existing.fetch(:state) == "open"
              raise RepositoryError, "lost recovery capture identity conflicts"
            end
            next
          end
          db[:payload_references].insert(
            payload_id: payload_id, attempt_id: attempt.attempt_id, task_id: nil,
            kind: "lost_capture", relative_path: relative, state: "open",
            created_at: now.utc.iso8601(6)
          )
        end
      rescue InvalidOutputReference => error
        raise RepositoryError, error.message
      end

      def validate!(data)
        valid = data.is_a?(Hash) && data["schema"] == "hive-attempt-lost-recovery" &&
          data["schema_version"] == 1 && !data["attempt_id"].to_s.empty? &&
          PHASES.include?(data["phase"]) && data["revision"].is_a?(Integer) &&
          data["revision"] >= 0 && data["updated_at"].is_a?(String) &&
          (data["phase"] != "complete" || !data["request_id"].to_s.empty?)
        raise RepositoryError, "lost recovery is invalid" unless valid
      end

      def validate_attempt!(attempt)
        return if attempt.is_a?(Record) && attempt.state == "lost"
        raise RepositoryError, "lost recovery requires a lost attempt"
      end

      def validate_identity!(current, attempt)
        return if current["attempt_id"] == attempt.attempt_id &&
          current["task_generation"] == attempt.task_generation

        raise RepositoryError, "lost recovery identity does not match attempt"
      end

      def validate_transition!(current, replacement, attempt)
        current_index = PHASES.index(current.fetch("phase"))
        replacement_index = PHASES.index(replacement.fetch("phase"))
        unless replacement_index && replacement_index >= current_index &&
               (replacement["cleanup"].nil? || CLEANUPS.include?(replacement["cleanup"]))
          raise RepositoryError, "lost recovery transition is invalid"
        end
        if replacement_index >= PHASES.index("ready") && replacement["request_id"].to_s.empty?
          raise RepositoryError, "ready lost recovery requires its deterministic request"
        end
        if replacement["request_id"] && replacement["request_id"] != recovery_request_id(attempt)
          raise RepositoryError, "lost recovery request identity is invalid"
        end
        true
      end

      def equivalent_or_later?(fresh, requested)
        PHASES.index(fresh.fetch("phase")) >= PHASES.index(requested.fetch("phase")) &&
          fresh["cleanup"] == requested["cleanup"] && fresh["request_id"] == requested["request_id"]
      end

      def stringify(hash)
        hash.to_h.transform_keys(&:to_s)
      end
    end

    # Performs cleanup and observational worktree capture before successor
    # policy. Unsafe process identity remains pending: a later observation may
    # prove the old process gone, so this error must not become a permanent
    # durable retry state.
    class LostOutcomeProcessor
      def initialize(store:, outcome_store:, process_identity:, dirty_capture: nil,
                     task_resolver: nil, orphan_grace_sec: 2)
        @store = store
        @outcome_store = outcome_store
        @process_identity = process_identity
        @dirty_capture = dirty_capture || DirtyStateCapture.new(store: store)
        @task_resolver = task_resolver || method(:resolve_task)
        @orphan_grace_sec = orphan_grace_sec
      end

      def process(attempt, now: Time.now.utc)
        outcome = @outcome_store.ensure_for(attempt, now: now)
        return outcome if LostOutcomeTransition::FINAL_PHASES.include?(outcome["phase"])
        return outcome if outcome["phase"] == "ready"
        return outcome unless cleanup_retry_due?(outcome, now: now)

        cleanup = cleanup_orphan(attempt)
        unless LostOutcomeTransition::SAFE_CLEANUPS.include?(cleanup)
          return @outcome_store.update(
            attempt, now: now, phase: "pending", cleanup: cleanup
          )
        end

        task = @task_resolver.call(attempt)
        capture = capture(task, attempt, now: now)
        @outcome_store.update(
          attempt, now: now, phase: "ready", cleanup: cleanup,
          request_id: @outcome_store.recovery_request_id(attempt),
          capture_references: capture&.references || []
        )
      rescue CompareAndSwapFailed
        @outcome_store.fetch(attempt.attempt_id) || raise
      end

      private

      def cleanup_retry_due?(outcome, now:)
        return true if outcome["cleanup"].nil?

        last_cleanup_at = Time.parse(outcome["updated_at"].to_s)
        Hive::AgentLimit.retry_due?(limited_at: last_cleanup_at, now: now)
      rescue ArgumentError, TypeError
        true
      end

      def cleanup_orphan(attempt)
        return "no_worker" unless attempt.worker

        @process_identity.terminate_orphan_group(
          wrapper: attempt.wrapper,
          worker: attempt.worker,
          grace_sec: @orphan_grace_sec
        ).to_s
      end

      def capture(task, attempt, now:)
        worktree = task&.worktree_path
        return nil unless worktree && File.directory?(worktree)

        @dirty_capture.capture(attempt: attempt, worktree: worktree, now: now)
      end

      def resolve_task(attempt)
        target = attempt["task_id"].to_s.empty? ? attempt["task_slug"] : attempt["task_id"]
        Hive::TaskResolver.new(target, project_filter: attempt["project"]).resolve
      rescue Hive::Error, SystemCallError
        nil
      end
    end
  end
end
