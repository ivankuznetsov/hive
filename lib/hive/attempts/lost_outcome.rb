require "digest"
require "time"
require "hive/agent_limit"
require "hive/attempts/dirty_state_capture"
require "hive/runtime_control_plane"
require "hive/task_resolver"

module Hive
  module Attempts
    # Transactional policy for cleanup after an irreversible lost lease. The
    # attempt remains ownership truth; this row prevents repeated signals and
    # duplicate successors across daemon restarts.
    class LostOutcomeTransition
      FINAL_STATUSES = %w[successor_dispatched].freeze
      SAFE_CLEANUPS = %w[absent terminated no_worker].freeze

      def initialize(store:)
        @store = store
      end

      def ensure_for(attempt, now: Time.now.utc)
        expected = {
            "schema" => "hive-attempt-lost-outcome",
            "schema_version" => 1,
            "idempotency_key" => idempotency_key(attempt),
            "attempt_id" => attempt.attempt_id,
            "task_generation" => attempt.task_generation,
            "project" => attempt["project"],
            "task_slug" => attempt["task_slug"],
            "status" => "pending",
            "created_at" => now.utc.iso8601(6),
            "updated_at" => now.utc.iso8601(6),
            "task_folder" => nil,
            "capture_references" => [],
            "cleanup" => nil,
            "successor_attempt_id" => nil,
            "last_cleanup_at" => nil,
            "last_retry_at" => nil,
            "diagnostic" => nil
        }
        @store.database.transaction do |db|
          row = db[:attempt_lost_outcomes].where(attempt_id: attempt.attempt_id).first
          next parse(row) if row

          db[:attempt_lost_outcomes].insert(row_for(expected, revision: 0))
          expected.freeze
        end
      rescue Sequel::Error, RuntimeControlPlane::Error => error
        raise RepositoryError, "lost outcome could not be created: #{error.message}"
      end

      def fetch(attempt_id)
        row = @store.database.read do |db|
          db[:attempt_lost_outcomes].where(attempt_id: attempt_id.to_s).first
        end
        row && parse(row)
      rescue Sequel::Error, RuntimeControlPlane::Error => error
        raise RepositoryError, "lost outcome #{attempt_id} is unreadable: #{error.message}"
      end

      def update(attempt, now: Time.now.utc, **changes)
        replacement = nil
        @store.database.transaction do |db|
          row = db[:attempt_lost_outcomes].where(attempt_id: attempt.attempt_id).first
          current = row && parse(row)
          raise RepositoryError, "lost outcome is missing" unless current
          unless current["idempotency_key"] == idempotency_key(attempt)
            raise RepositoryError, "lost outcome identity does not match attempt"
          end

          replacement = current.merge(stringify(changes)).merge(
            "updated_at" => now.utc.iso8601(6)
          )
          changed = db[:attempt_lost_outcomes].where(
            attempt_id: attempt.attempt_id, revision: row.fetch(:revision)
          ).update(row_for(replacement, revision: row.fetch(:revision) + 1))
          raise RepositoryError, "lost outcome changed concurrently" unless changed == 1
        end
        replacement.freeze
      rescue Sequel::Error, RuntimeControlPlane::Error => error
        raise RepositoryError, "lost outcome could not be updated: #{error.message}"
      end

      private

      def idempotency_key(attempt)
        ::Digest::SHA256.hexdigest(
          [ attempt.attempt_id, attempt.task_generation, attempt["loss"]["at"] ].join("\0")
        )
      end

      def row_for(data, revision:)
        validate!(data)
        {
          attempt_id: data.fetch("attempt_id"),
          idempotency_key: data.fetch("idempotency_key"),
          status: data.fetch("status"), cleanup: data["cleanup"],
          successor_attempt_id: data["successor_attempt_id"],
          value_json: RuntimeControlPlane::Codec.dump_json(data),
          revision: revision, updated_at: data.fetch("updated_at")
        }
      end

      def parse(row)
        data = RuntimeControlPlane::Codec.load_json(row.fetch(:value_json))
        validate!(data)
        unless data["attempt_id"] == row.fetch(:attempt_id) &&
               data["idempotency_key"] == row.fetch(:idempotency_key) &&
               data["status"] == row.fetch(:status) &&
               data["cleanup"] == row[:cleanup] &&
               data["successor_attempt_id"] == row[:successor_attempt_id]
          raise RepositoryError, "lost outcome indexed fields disagree with its value"
        end
        data.freeze
      end

      def validate!(data)
        valid = data.is_a?(Hash) && data["schema"] == "hive-attempt-lost-outcome" &&
          data["schema_version"] == 1 && !data["attempt_id"].to_s.empty? &&
          !data["idempotency_key"].to_s.empty? &&
          %w[pending ready successor_dispatched].include?(data["status"])
        raise RepositoryError, "lost outcome is invalid" unless valid
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
        return outcome if LostOutcomeTransition::FINAL_STATUSES.include?(outcome["status"])
        return outcome if outcome["status"] == "ready"
        return outcome unless cleanup_retry_due?(outcome, now: now)

        cleanup = cleanup_orphan(attempt)
        unless LostOutcomeTransition::SAFE_CLEANUPS.include?(cleanup)
          diagnostic = "worker group identity is not safe to terminate yet; retrying"
          return @outcome_store.update(
            attempt, now: now, status: "pending", cleanup: cleanup,
            last_cleanup_at: now.utc.iso8601(6),
            diagnostic: diagnostic
          )
        end

        task = @task_resolver.call(attempt)
        capture = capture(task, attempt, now: now)
        current = @store.fetch(attempt.attempt_id)
        annotated = @store.annotate_lost(
          current,
          output_references: capture&.references || [],
          diagnostics: {
            "cleanup" => cleanup,
            "dirty_capture" => capture && File.join(capture.directory, "manifest.json")
          }.compact,
          now: now
        )
        @outcome_store.update(
          annotated, now: now, status: "ready", cleanup: cleanup,
          task_folder: task&.folder,
          capture_references: capture&.references || [],
          diagnostic: nil
        )
      rescue CompareAndSwapFailed
        @outcome_store.fetch(attempt.attempt_id) || raise
      end

      private

      def cleanup_retry_due?(outcome, now:)
        last_cleanup_at = Time.parse(outcome["last_cleanup_at"].to_s)
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
