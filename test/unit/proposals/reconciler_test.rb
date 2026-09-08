require "test_helper"
require "hive/proposals/reconciler"

class ProposalReconcilerTest < Minitest::Test
  include HiveTestHelper

  def test_replays_only_committed_pending_receipts_and_cleans_crash_left_canonical_files
    with_tmp_git_repo do |dir|
      ops, source_store, store = stores(dir)
      event = submission
      source_store.admit!(event)
      commit_admission(ops, source_store, event)
      crash_left = File.join(store.records_root, "prp-00000000-0000-4000-8000-000000000099.json")
      FileUtils.mkdir_p(File.dirname(crash_left))
      File.write(crash_left, "uncommitted")

      result = reconciler(ops, source_store, store).reconcile!
      second = reconciler(ops, source_store, store).reconcile!

      assert_equal 1, result.processed
      assert_equal 1, result.consumed
      assert_equal 0, result.quarantined
      assert_operator result.cleaned, :>=, 1
      assert_equal 0, second.processed
      refute File.exist?(crash_left)
      assert_equal "draft", store.projection(event.proposal_id).status
      assert_empty source_store.pending_ids
    end
  end

  def test_terminally_quarantines_a_malformed_committed_receipt_without_retrying
    with_tmp_git_repo do |dir|
      ops, source_store, store = stores(dir)
      event = submission
      source_store.admit!(event)
      path = source_store.paths_for_admission(event.source_event_id).first
      File.write(path, "{malformed")
      commit_admission(ops, source_store, event)

      result = reconciler(ops, source_store, store).reconcile!
      second = reconciler(ops, source_store, store).reconcile!

      assert_equal 1, result.quarantined
      assert_equal 0, second.processed
      assert_equal "quarantine", source_store.status(event.source_event_id).fetch("state")
      assert_nil store.projection(event.proposal_id)
      assert_empty source_store.pending_ids
    end
  end

  def test_removes_uncommitted_receipts_without_ingesting_them
    with_tmp_git_repo do |dir|
      ops, source_store, store = stores(dir)
      event = submission
      source_store.admit!(event)

      result = reconciler(ops, source_store, store).reconcile!

      assert_equal 0, result.processed
      assert_operator result.cleaned, :>=, 2
      assert_nil store.projection(event.proposal_id)
      assert_nil source_store.fetch(event.source_event_id)
    end
  end

  def test_transient_source_unavailability_remains_pending_for_replay
    with_tmp_git_repo do |dir|
      ops, source_store, store = stores(dir)
      event = submission
      source_store.admit!(event)
      commit_admission(ops, source_store, event)
      unavailable = Object.new
      unavailable.define_singleton_method(:ingest!) do |*_arguments, **_options|
        raise Hive::Proposals::SourceUnavailable, "temporary missing blob"
      end
      reconciler = Hive::Proposals::Reconciler.new(
        git_ops: ops, source_store:, store:, ingestor: unavailable, max_batch: 8
      )

      result = reconciler.reconcile!

      assert_equal 1, result.processed
      assert_equal 0, result.quarantined
      assert_equal 1, result.pending
      assert_equal "pending", source_store.status(event.source_event_id).fetch("state")
    end
  end

  def test_failed_quarantine_commit_restores_pending_state_and_tolerates_reset_failure
    with_tmp_git_repo do |dir|
      ops, source_store, store = stores(dir)
      event = submission
      source_store.admit!(event)
      commit_admission(ops, source_store, event)
      reconciler = reconciler(ops, source_store, store)
      ops.define_singleton_method(:hive_commit) do |**_options|
        raise Hive::GitError, "simulated quarantine commit failure"
      end
      original_run_git = ops.method(:run_git!)
      ops.define_singleton_method(:run_git!) do |*arguments|
        raise Hive::GitError, "simulated reset failure" if arguments.include?("read-tree")
        original_run_git.call(*arguments)
      end

      assert_raises(Hive::GitError) do
        reconciler.send(
          :quarantine_source!, event.source_event_id,
          Hive::Proposals::InvalidRecord.new("bad receipt")
        )
      end
      assert_equal "pending", source_store.status(event.source_event_id).fetch("state")
    end
  end

  def test_cleanup_restores_tracked_paths_and_removes_untracked_directories_idempotently
    with_tmp_git_repo do |dir|
      ops, source_store, store = stores(dir)
      relative = "proposals/v1/records/tracked.txt"
      path = File.join(ops.hive_state_path, relative)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, "committed\n")
      ops.hive_commit(
        stage_name: "proposals", slug: "fixture", action: "recorded tracked fixture",
        pathspecs: [ relative ]
      )
      File.write(path, "dirty\n")
      reconciler = reconciler(ops, source_store, store)

      assert_equal 1, reconciler.send(:clean_uncommitted_state!)
      assert_equal "committed\n", File.read(path)

      directory = File.join(ops.hive_state_path, "proposals", "v1", "scratch")
      FileUtils.mkdir_p(directory)
      File.write(File.join(directory, "temporary"), "temporary")
      reconciler.send(:remove_untracked!, "proposals/v1/scratch")
      refute File.exist?(directory)
      assert_nil reconciler.send(:remove_untracked!, "proposals/v1/missing")
    end
  end

  private

  def stores(dir)
    ops = Hive::GitOps.new(dir)
    ops.hive_state_init
    root = File.join(ops.hive_state_path, "proposals", "v1")
    source_store = Hive::Proposals::SourceEventStore.new(root: root)
    store = Hive::Proposals::Store.new(root: root)
    [ ops, source_store, store ]
  end

  def reconciler(ops, source_store, store)
    Hive::Proposals::Reconciler.new(
      git_ops: ops, source_store: source_store, store: store, max_batch: 8
    )
  end

  def commit_admission(ops, source_store, event)
    paths = source_store.paths_for_admission(event.source_event_id).map do |path|
      path.delete_prefix("#{ops.hive_state_path}/")
    end
    ops.hive_commit(
      stage_name: "4-execute", slug: "proposal-task", action: "source only",
      pathspecs: paths
    )
  end

  def submission
    Hive::Proposals::SourceEvent.submission(
      source_event_id: "pse-#{'a' * 64}",
      proposal_id: "prp-00000000-0000-4000-8000-000000000001",
      proposal_binding: {
        "schema_version" => 1,
        "subject" => {
          "kind" => "workflow", "reference" => "coding", "revision" => "v2",
          "proposal_id" => "prp-00000000-0000-4000-8000-000000000001"
        },
        "actor" => { "id" => "alice", "kind" => "proposer", "binding" => "team:workflow" },
        "evaluator" => nil, "configuration_fingerprint" => "c" * 64,
        "policy" => {
          "visibility" => "project", "retention" => "project",
          "allowed_link_schemes" => [ "https" ]
        }
      },
      task_binding: {
        "project" => "hive", "task_id" => "43059", "task_slug" => "proposal-task",
        "workflow_id" => "coding", "stage" => "4-execute", "task_generation" => 1,
        "ownership_generation" => "owner-1", "attempt_id" => "attempt-1"
      },
      proposed_change: "Change review", motivation: "Improve quality",
      evidence: [ { "label" => "test", "content" => "pass", "media_type" => "text/plain" } ],
      created_at: "2026-08-30T12:00:00Z"
    )
  end
end
