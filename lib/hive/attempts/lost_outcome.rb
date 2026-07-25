require "digest"
require "fileutils"
require "json"
require "time"
require "hive/atomic_file"
require "hive/agent_limit"
require "hive/attempts/dirty_state_capture"
require "hive/task_resolver"

module Hive
  module Attempts
    # Durable, idempotent policy projection of an irreversible lost lease.
    # The attempt record remains ownership truth; this small sidecar records
    # cleanup/preservation progress so daemon restarts cannot repeat signals
    # or mint another successor.
    class LostOutcomeStore
      FINAL_STATUSES = %w[successor_dispatched].freeze

      def initialize(store:)
        @store = store
      end

      def ensure_for(attempt, now: Time.now.utc)
        @store.with_generation_lock(attempt.task_generation) do
          fetch(attempt.attempt_id) || persist(attempt, {
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
          })
        end
      end

      def fetch(attempt_id)
        JSON.parse(File.binread(path(attempt_id)))
      rescue Errno::ENOENT
        nil
      rescue JSON::ParserError => e
        raise StoreError, "lost outcome #{attempt_id} is unreadable: #{e.message}"
      end

      def update(attempt, now: Time.now.utc, **changes)
        @store.with_generation_lock(attempt.task_generation) do
          current = fetch(attempt.attempt_id) || raise(StoreError, "lost outcome is missing")
          unless current["idempotency_key"] == idempotency_key(attempt)
            raise StoreError, "lost outcome identity does not match attempt"
          end

          persist(attempt, current.merge(stringify(changes)).merge(
            "updated_at" => now.utc.iso8601(6)
          ))
        end
      end

      private

      def idempotency_key(attempt)
        ::Digest::SHA256.hexdigest(
          [ attempt.attempt_id, attempt.task_generation, attempt["loss"]["at"] ].join("\0")
        )
      end

      def path(attempt_id)
        File.join(@store.outputs_root, attempt_id, "lost-outcome.json")
      end

      def persist(attempt, data)
        output_dir = File.join(@store.outputs_root, attempt.attempt_id)
        FileUtils.mkdir_p(output_dir, mode: 0o700)
        File.chmod(0o700, output_dir)
        Hive::AtomicFile.write(path(attempt.attempt_id), JSON.generate(data) + "\n", mode: 0o600)
        File.chmod(0o600, path(attempt.attempt_id))
        data
      rescue SystemCallError, IOError => e
        raise StoreError, "lost outcome could not be persisted: #{e.message}"
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
        return outcome if LostOutcomeStore::FINAL_STATUSES.include?(outcome["status"])
        return outcome if outcome["status"] == "ready"
        return outcome unless cleanup_retry_due?(outcome, now: now)

        cleanup = cleanup_orphan(attempt)
        unless %w[absent terminated no_worker].include?(cleanup)
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
