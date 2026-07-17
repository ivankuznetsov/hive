require "time"
require "hive/babysitter/job_store"
require "hive/finalization/event"
require "hive/finalization/reconciler"
require "hive/git_ops"
require "hive/task_journal"
require "hive/task_projection/store"
require "hive/worktree"

module Hive
  module Finalization
    # Removes retained task recovery state only after the authoritative
    # archive gate has opened. Every destructive target is re-derived from
    # the current journal, babysitter job, and registered worktree metadata;
    # worktree.yml is never trusted as an arbitrary deletion instruction.
    class ArchiveCleanup
      Result = Data.define(:status, :event_id, :worktree, :branch)

      def initialize(task:, clock: -> { Time.now.utc }, job_store: nil,
                     worktree_factory: nil, git_ops: nil, after_step: nil)
        @task = task
        @clock = clock
        @job_store = job_store || Hive::Babysitter::JobStore.new(project_root: task.project_root)
        @worktree_factory = worktree_factory || lambda do |root, slug|
          Hive::Worktree.new(root, slug, worktree_root: Hive::Worktree.canonical_root(root))
        end
        @git_ops = git_ops || Hive::GitOps.new(task.project_root)
        @after_step = after_step
      end

      def call
        records = Hive::TaskProjection.read_journal(journal_path)
        validate_history!(records)
        finalization = Hive::Finalization::Projection.project(records: records)
        unless finalization.fetch("state") == "archive_ready"
          raise Hive::Finalization::StaleEvidence, "cleanup requires current archive_ready evidence"
        end
        if (receipt = finalization.dig("evidence", "cleanup_event_id"))
          return Result.new(status: :already_completed, event_id: receipt,
                            worktree: nil, branch: nil)
        end

        job = validate_job_owner!(finalization)
        pointer = validated_pointer!(job)
        worktree_path = pointer.fetch("path")
        branch = pointer.fetch("branch")

        remove_worktree!(worktree_path)
        @after_step&.call(:worktree_removed)
        @git_ops.prune_worktrees_strict!
        ensure_worktree_absent!(worktree_path)

        remove_branch!(branch)
        @after_step&.call(:branch_deleted)

        event_id = append_receipt!(records, finalization, worktree_path, branch)
        Hive::TaskProjection::Store.new(task_folder: @task.folder).rebuild!
        @after_step&.call(:receipt_appended)
        Result.new(status: :completed, event_id: event_id,
                   worktree: worktree_path, branch: branch)
      end

      private

      def journal_path
        File.join(@task.folder, Hive::TaskJournal::JOURNAL_BASENAME)
      end

      def validate_history!(records)
        validated = []
        records.each do |record|
          Hive::Finalization::Event.validate!(record, records: validated) if
            Hive::Finalization::Event.finalization?(record)
          validated << record
        end
      end

      def validate_job_owner!(finalization)
        job = @job_store.current_job(
          task_slug: @task.slug,
          task_generation: finalization.fetch("task_generation")
        )
        unless job && job.fetch("job_id") == finalization.fetch("job_id")
          raise Hive::Finalization::StaleEvidence, "cleanup job is not current for this task generation"
        end
        expected = {
          "repository" => job.dig("identity", "repository"),
          "pr_number" => job.dig("identity", "pr_number"),
          "head_sha" => job["head_sha"],
          "head_generation" => job["head_generation"],
          "finalize_attempt_id" => job["finalize_attempt_id"]
        }
        stale = expected.filter_map { |key, value| key unless finalization[key] == value }
        unless stale.empty?
          raise Hive::Finalization::StaleEvidence, "cleanup ownership is stale: #{stale.join(', ')}"
        end
        unless job.fetch("state") == "terminal"
          raise Hive::Finalization::StaleEvidence, "cleanup requires a terminal babysitter job"
        end
        if live_claim?(job)
          raise Hive::Finalization::StaleEvidence, "cleanup is blocked by a live babysitter claim"
        end
        newer = @job_store.jobs.any? do |candidate|
          identity = candidate.fetch("identity")
          identity.fetch("task_slug") == @task.slug &&
            identity.fetch("task_generation") > finalization.fetch("task_generation")
        end
        if newer
          raise Hive::Finalization::StaleEvidence, "a newer task generation owns the local recovery branch"
        end
        job
      end

      def live_claim?(job)
        now = @clock.call
        job.fetch("claims").any? do |claim|
          claim["state"] == "active" && Time.iso8601(claim.fetch("expires_at")) > now
        end
      rescue ArgumentError, KeyError => e
        raise Hive::Finalization::StaleEvidence, "cleanup claim evidence is invalid: #{e.message}"
      end

      def validated_pointer!(job)
        pointer = Hive::Worktree.read_pointer(@task.folder)
        unless pointer.is_a?(Hash) && !pointer["path"].to_s.empty? && !pointer["branch"].to_s.empty?
          raise Hive::WorktreeError, "archive cleanup requires the retained worktree pointer"
        end
        expected_root = Hive::Worktree.canonical_root(@task.project_root)
        validated = Hive::Worktree.validate_pointer_path(pointer.fetch("path"), expected_root)
        expected_path = File.join(expected_root, @task.slug)
        unless validated == expected_path
          raise Hive::WorktreeError,
                "worktree pointer #{validated} does not match expected task path #{expected_path}"
        end
        unless pointer.fetch("branch") == job.fetch("branch")
          raise Hive::WorktreeError, "worktree pointer branch does not match the current babysitter job"
        end
        { "path" => validated, "branch" => pointer.fetch("branch") }
      end

      def remove_worktree!(path)
        worktree = @worktree_factory.call(@task.project_root, @task.slug)
        registered = worktree.list_worktree_paths.map { |candidate| File.expand_path(candidate) }.include?(path)
        if registered && File.exist?(path)
          worktree.remove!(path: path)
        elsif registered
          @git_ops.prune_worktrees_strict!
        elsif File.exist?(path)
          raise Hive::WorktreeError, "refusing to remove unregistered worktree path #{path}"
        end
      end

      def ensure_worktree_absent!(path)
        worktree = @worktree_factory.call(@task.project_root, @task.slug)
        registered = worktree.list_worktree_paths.map { |candidate| File.expand_path(candidate) }.include?(path)
        return unless registered || File.exist?(path)

        raise Hive::WorktreeError, "task worktree cleanup did not remove #{path}"
      end

      def remove_branch!(branch)
        return unless @git_ops.ref_exists?("refs/heads/#{branch}")

        @git_ops.delete_branch!(branch)
        return unless @git_ops.ref_exists?("refs/heads/#{branch}")

        raise Hive::GitError, "local task branch #{branch} remains checked out or owned"
      end

      def append_receipt!(records, finalization, worktree_path, branch)
        archive_event_id = finalization.dig("evidence", "archive_ready_event_id")
        archive_event = records.find { |record| record["event_id"] == archive_event_id }
        task_identity = archive_event&.fetch("task", nil)
        unless task_identity.is_a?(Hash)
          raise Hive::Finalization::StaleEvidence, "archive_ready task identity is missing"
        end
        now = @clock.call.utc.iso8601(6)
        event_id = "#{finalization.fetch('job_id')}:cleanup:#{archive_event_id}"
        coordinates = Hive::Finalization::Event::COORDINATES.to_h do |key|
          [ key, finalization.fetch(key) ]
        end
        Hive::TaskJournal::Writer.new(task_folder: @task.folder, clock: @clock).append_once(
          event_id: event_id,
          event_type: "cleanup_completed",
          occurred_at: now,
          observed_at: now,
          task: task_identity,
          workflow: archive_event["workflow"] || "coding",
          stage: "#{@task.stage_index}-#{@task.stage_name}",
          attempt_id: finalization.fetch("finalize_attempt_id"),
          task_generation: finalization.fetch("task_generation"),
          ownership_generation: "finalization-reconciler-v1",
          reason: "validated local recovery state removed",
          producer: Hive::Finalization::Reconciler::PRODUCER,
          evidence: [ { "kind" => "journal_event", "event_id" => archive_event_id } ],
          provenance: { "source" => "hive-finalization-archive-cleanup" },
          payload: coordinates.merge(
            "archive_ready_event_id" => archive_event_id,
            "worktree_path" => worktree_path,
            "local_branch" => branch,
            "remote_branch_deleted" => false
          )
        ).event_id
      end
    end
  end
end
