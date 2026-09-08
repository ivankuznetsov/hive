require "test_helper"
require "hive/proposals/ingestor"

class ProposalIngestorTest < Minitest::Test
  include HiveTestHelper

  def test_ingests_a_submission_once_and_marks_the_source_consumed
    with_tmp_dir do |dir|
      source_store, store, ingestor = stores(dir)
      event = submission
      source_store.admit!(event)

      result = ingestor.ingest!(event.source_event_id, source_commit: "a" * 40)
      replay = ingestor.ingest!(event.source_event_id, source_commit: "a" * 40)

      assert_equal "record", result.kind
      assert_equal event.proposal_id, result.proposal_id
      assert_nil result.event_id
      assert_equal result, replay
      assert_equal "consumed", source_store.status(event.source_event_id).fetch("state")
      projection = store.projection(event.proposal_id)
      assert_equal "draft", projection.status
      assert_equal event.source_event_id, projection.record.source_event_id
      assert_equal "a" * 40, projection.record.provenance.fetch("source_commit")
    end
  end

  def test_ingests_an_evaluation_from_its_historical_admitted_binding
    with_tmp_dir do |dir|
      source_store, store, ingestor = stores(dir)
      source_store.admit!(submission)
      ingestor.ingest!(submission.source_event_id, source_commit: "a" * 40)
      event = evaluation
      source_store.admit!(event)

      result = ingestor.ingest!(event.source_event_id, source_commit: "b" * 40)

      assert_equal "event", result.kind
      assert_match(/\Apev-/, result.event_id)
      projection = store.projection(event.proposal_id)
      assert_equal 1, projection.evaluations.length
      assert_equal "benchmark-reviewer", projection.evaluations.first.dig("evaluator", "id")
      assert_equal "b" * 40, projection.evaluations.first.dig("provenance", "source_commit")
    end
  end

  def test_terminal_quarantine_and_unknown_source_kinds_fail_closed
    with_tmp_dir do |dir|
      source_store, store, ingestor = stores(dir)
      source_store.admit!(submission)
      source_store.quarantine!(submission.source_event_id, code: "invalid", reason: "invalid source")

      assert_raises(Hive::Proposals::QuarantinedSource) do
        ingestor.ingest!(submission.source_event_id, source_commit: "a" * 40)
      end

      unsupported = Struct.new(:kind).new("future_kind")
      assert_raises(Hive::Proposals::InvalidRecord) do
        ingestor.send(:mutate!, unsupported, source_commit: "a" * 40)
      end
      assert_nil store.projection(proposal_id)
    end
  end

  def test_failed_canonical_commit_after_staging_restores_record_status_and_index
    with_tmp_git_repo do |dir|
      ops = Hive::GitOps.new(dir)
      ops.hive_state_init
      root = File.join(ops.hive_state_path, "proposals", "v1")
      source_store = Hive::Proposals::SourceEventStore.new(root: root)
      store = Hive::Proposals::Store.new(root: root, id_generator: id_sequence)
      source_store.admit!(submission)
      source_paths = source_store.paths_for_admission(submission.source_event_id).map do |path|
        path.delete_prefix("#{ops.hive_state_path}/")
      end
      ops.hive_commit(
        stage_name: "4-execute", slug: "proposal-task", action: "source only",
        pathspecs: source_paths
      )
      source_commit = ops.hive_state_head_sha
      original_commit = ops.method(:hive_commit)
      ops.define_singleton_method(:hive_commit) do |**options|
        original_commit.call(**options.merge(after_stage: -> { raise Hive::GitError, "after staging" }))
      end
      ingestor = Hive::Proposals::Ingestor.new(
        source_store:, store:, git_ops: ops
      )

      assert_raises(Hive::GitError) do
        ingestor.ingest!(submission.source_event_id, source_commit:)
      end
      assert_nil store.projection(proposal_id)
      assert_equal "pending", source_store.status(submission.source_event_id).fetch("state")
      assert_equal "", run!("git", "-C", ops.hive_state_path, "status", "--porcelain=v1")
    end
  end

  def test_uncommitted_consumed_marker_is_cleaned_and_reingested_before_success
    with_tmp_git_repo do |dir|
      ops = Hive::GitOps.new(dir)
      ops.hive_state_init
      root = File.join(ops.hive_state_path, "proposals", "v1")
      source_store = Hive::Proposals::SourceEventStore.new(root: root)
      store = Hive::Proposals::Store.new(root: root, id_generator: id_sequence)
      source_store.admit!(submission)
      paths = source_store.paths_for_admission(submission.source_event_id).map do |path|
        path.delete_prefix("#{ops.hive_state_path}/")
      end
      ops.hive_commit(
        stage_name: "4-execute", slug: "proposal-task", action: "source only", pathspecs: paths
      )
      source_commit = ops.hive_state_head_sha
      Hive::Proposals::Ingestor.new(source_store:, store:).ingest!(
        submission.source_event_id, source_commit:
      )
      assert_equal "consumed", source_store.status(submission.source_event_id).fetch("state")

      result = Hive::Proposals::Ingestor.new(
        source_store:, store:, git_ops: ops
      ).ingest!(submission.source_event_id, source_commit:)

      assert_equal "record", result.kind
      assert_equal "consumed", source_store.status(submission.source_event_id).fetch("state")
      assert_equal "", run!("git", "-C", ops.hive_state_path, "status", "--porcelain=v1")
      assert_includes run!("git", "-C", ops.hive_state_path, "show", "--name-only", "--format=", "HEAD"),
                      "proposals/v1/records/#{proposal_id}.json"
    end
  end

  def test_nothing_to_commit_cannot_report_success_for_uncommitted_terminal_files
    with_tmp_git_repo do |dir|
      ops = Hive::GitOps.new(dir)
      ops.hive_state_init
      root = File.join(ops.hive_state_path, "proposals", "v1")
      source_store = Hive::Proposals::SourceEventStore.new(root: root)
      store = Hive::Proposals::Store.new(root: root, id_generator: id_sequence)
      source_store.admit!(submission)
      paths = source_store.paths_for_admission(submission.source_event_id).map do |path|
        path.delete_prefix("#{ops.hive_state_path}/")
      end
      ops.hive_commit(
        stage_name: "4-execute", slug: "proposal-task", action: "source only", pathspecs: paths
      )
      source_commit = ops.hive_state_head_sha
      ops.define_singleton_method(:hive_commit) { |**_options| :nothing_to_commit }
      ingestor = Hive::Proposals::Ingestor.new(source_store:, store:, git_ops: ops)

      assert_raises(Hive::Proposals::SourceUnavailable) do
        ingestor.ingest!(submission.source_event_id, source_commit:)
      end
      assert_nil store.projection(proposal_id)
      assert_equal "pending", source_store.status(submission.source_event_id).fetch("state")
    end
  end

  def test_reported_commit_without_durable_files_restores_the_target
    with_tmp_git_repo do |dir|
      ops = Hive::GitOps.new(dir)
      ops.hive_state_init
      root = File.join(ops.hive_state_path, "proposals", "v1")
      source_store = Hive::Proposals::SourceEventStore.new(root: root)
      store = Hive::Proposals::Store.new(root: root, id_generator: id_sequence)
      source_store.admit!(submission)
      paths = source_store.paths_for_admission(submission.source_event_id).map do |path|
        path.delete_prefix("#{ops.hive_state_path}/")
      end
      ops.hive_commit(
        stage_name: "4-execute", slug: "proposal-task", action: "source only", pathspecs: paths
      )
      source_commit = ops.hive_state_head_sha
      ops.define_singleton_method(:hive_commit) { |**_options| :committed }
      ingestor = Hive::Proposals::Ingestor.new(source_store:, store:, git_ops: ops)

      assert_raises(Hive::Proposals::SourceUnavailable) do
        ingestor.ingest!(submission.source_event_id, source_commit:)
      end
      assert_nil store.projection(proposal_id)
      assert_equal "pending", source_store.status(submission.source_event_id).fetch("state")
    end
  end

  def test_committed_terminal_quarantine_is_final
    with_tmp_git_repo do |dir|
      ops = Hive::GitOps.new(dir)
      ops.hive_state_init
      root = File.join(ops.hive_state_path, "proposals", "v1")
      source_store = Hive::Proposals::SourceEventStore.new(root: root)
      store = Hive::Proposals::Store.new(root: root, id_generator: id_sequence)
      source_store.admit!(submission)
      admission_paths = source_store.paths_for_admission(submission.source_event_id).map do |path|
        path.delete_prefix("#{ops.hive_state_path}/")
      end
      ops.hive_commit(
        stage_name: "4-execute", slug: "proposal-task", action: "source only",
        pathspecs: admission_paths
      )
      source_commit = ops.hive_state_head_sha
      source_store.quarantine!(submission.source_event_id, code: "invalid", reason: "invalid")
      terminal_paths = source_store.paths_for_terminal(
        submission.source_event_id, state: "quarantine"
      ).map { |path| path.delete_prefix("#{ops.hive_state_path}/") }
      ops.hive_commit(
        stage_name: "proposal-reconcile", slug: "proposal-task", action: "quarantined source",
        pathspecs: terminal_paths
      )

      assert_raises(Hive::Proposals::QuarantinedSource) do
        Hive::Proposals::Ingestor.new(
          source_store:, store:, git_ops: ops
        ).ingest!(submission.source_event_id, source_commit:)
      end
    end
  end

  def test_committed_terminal_verification_rejects_inconsistent_results
    with_tmp_dir do |dir|
      source_store, store, plain_ingestor = stores(dir)
      source_store.admit!(submission)
      result = plain_ingestor.ingest!(submission.source_event_id, source_commit: "a" * 40)
      terminal = source_store.status(submission.source_event_id)
      git_ops = Object.new
      git_ops.define_singleton_method(:hive_state_path) { dir }
      git_ops.define_singleton_method(:hive_state_head_sha) { "a" * 40 }
      blobs = {}
      git_ops.define_singleton_method(:read_hive_state_blob_at) do |_commit, path, **_options|
        blobs[path]
      end
      ingestor = Hive::Proposals::Ingestor.new(source_store:, store:, git_ops:)

      assert_raises(Hive::Proposals::SourceUnavailable) do
        ingestor.send(:verify_committed_terminal!, nil, result)
      end

      mismatched = Hive::Proposals::IngestionResult.new(
        kind: "record", proposal_id:, event_id: nil, source_event_id: "pse-#{'b' * 64}"
      )
      mismatched_terminal = terminal.merge(
        "source_event_id" => mismatched.source_event_id, "result" => mismatched.to_h
      )
      mismatched_status_path = source_store.paths_for_terminal(
        mismatched.source_event_id, state: "consumed"
      ).first.delete_prefix("#{dir}/")
      blobs[mismatched_status_path] = Hive::Proposals.canonical(mismatched_terminal)
      assert_raises(Hive::Proposals::QuarantinedSource) do
        ingestor.send(:verify_committed_terminal!, mismatched_terminal, mismatched)
      end

      status_path = source_store.paths_for_terminal(
        result.source_event_id, state: "consumed"
      ).first.delete_prefix("#{dir}/")
      blobs[status_path] = Hive::Proposals.canonical(terminal)
      assert_raises(Hive::Proposals::SourceUnavailable) do
        ingestor.send(:verify_committed_terminal!, terminal, result)
      end
    end
  end

  def test_committed_target_cleanup_removes_files_directories_and_missing_paths
    with_tmp_dir do |dir|
      ingestor = Hive::Proposals::Ingestor.new(source_store: Object.new, store: Object.new)
      directory = File.join(dir, "directory")
      file = File.join(dir, "file")
      missing = File.join(dir, "missing")
      FileUtils.mkdir_p(directory)
      File.write(File.join(directory, "nested"), "data")
      File.write(file, "data")

      ingestor.send(:remove_path, directory)
      ingestor.send(:remove_path, file)

      refute File.exist?(directory)
      refute File.exist?(file)
      assert_nil ingestor.send(:remove_path, missing)
    end
  end

  def test_evaluation_subject_must_match_the_immutable_candidate
    with_tmp_dir do |dir|
      source_store, store, ingestor = stores(dir)
      source_store.admit!(submission)
      ingestor.ingest!(submission.source_event_id, source_commit: "a" * 40)
      binding = Marshal.load(Marshal.dump(proposal_binding(evaluator: evaluator)))
      binding.dig("subject")["reference"] = "agent-skills/planner"
      mismatched = Hive::Proposals::SourceEvent.evaluation(
        source_event_id: "pse-#{'c' * 64}", proposal_id: proposal_id,
        proposal_binding: binding, task_binding: task_binding,
        method: { "kind" => "benchmark", "label" => "held-out recall" },
        result: { "outcome" => "pass", "metrics" => { "recall" => 0.91 } },
        rationale: "No protected regression", evidence: [ evidence ], links: [],
        created_at: "2026-08-30T12:05:00Z"
      )
      source_store.admit!(mismatched)

      assert_raises(Hive::Proposals::Conflict) do
        ingestor.ingest!(mismatched.source_event_id, source_commit: "b" * 40)
      end
      assert_equal "pending", source_store.status(mismatched.source_event_id).fetch("state")
    end
  end

  def test_path_snapshot_restores_symlinks_exactly
    with_tmp_dir do |dir|
      path = File.join(dir, "receipt")
      File.symlink("target.json", path)
      snapshot = Hive::Proposals::Ingestor::PathSnapshot.capture([ path ])
      File.unlink(path)
      File.write(path, "replacement")

      snapshot.restore!

      assert File.symlink?(path)
      assert_equal "target.json", File.readlink(path)
    end
  end

  def test_immutable_append_snapshot_removes_only_new_event_entries
    with_tmp_dir do |dir|
      event_dir = File.join(dir, "events", proposal_id)
      FileUtils.mkdir_p(event_dir)
      existing = File.join(event_dir, "1-existing.json")
      File.write(existing, "immutable")
      snapshot = Hive::Proposals::Ingestor::ImmutableAppendSnapshot.capture(event_dir)

      File.write(File.join(event_dir, "2-new.json"), "new")
      snapshot.restore!

      assert_equal "immutable", File.read(existing)
      refute File.exist?(File.join(event_dir, "2-new.json"))

      absent_dir = File.join(dir, "events", "new-proposal")
      absent = Hive::Proposals::Ingestor::ImmutableAppendSnapshot.capture(absent_dir)
      FileUtils.mkdir_p(absent_dir)
      File.write(File.join(absent_dir, "1-new.json"), "new")
      absent.restore!
      refute File.exist?(absent_dir)
    end
  end

  def test_immutable_append_snapshot_rejects_non_directories_and_tolerates_missing_restore
    with_tmp_dir do |dir|
      path = File.join(dir, "event-path")
      File.write(path, "not a directory")
      assert_raises(Hive::Proposals::Error) do
        Hive::Proposals::Ingestor::ImmutableAppendSnapshot.capture(path)
      end

      File.unlink(path)
      snapshot = Hive::Proposals::Ingestor::ImmutableAppendSnapshot.capture(path)
      assert_nil snapshot.restore!

      FileUtils.mkdir_p(path)
      existing = Hive::Proposals::Ingestor::ImmutableAppendSnapshot.capture(path)
      FileUtils.rm_rf(path)
      assert_nil existing.restore!
    end
  end

  def test_path_snapshot_restores_directory_trees
    with_tmp_dir do |dir|
      root = File.join(dir, "state")
      nested = File.join(root, "nested")
      FileUtils.mkdir_p(nested)
      File.write(File.join(nested, "record.json"), "original")
      snapshot = Hive::Proposals::Ingestor::PathSnapshot.capture([ root ])

      FileUtils.rm_rf(root)
      FileUtils.mkdir_p(root)
      File.write(File.join(root, "replacement.json"), "replacement")
      snapshot.restore!

      assert_equal "original", File.read(File.join(nested, "record.json"))
      refute File.exist?(File.join(root, "replacement.json"))

      FileUtils.rm_rf(root)
      snapshot.restore!
      assert_equal "original", File.read(File.join(nested, "record.json"))
    end
  end

  private

  def stores(dir)
    root = File.join(dir, "proposals", "v1")
    source_store = Hive::Proposals::SourceEventStore.new(root: root)
    store = Hive::Proposals::Store.new(root: root, id_generator: id_sequence)
    [ source_store, store,
      Hive::Proposals::Ingestor.new(source_store: source_store, store: store) ]
  end

  def id_sequence
    values = %w[
      00000000-0000-4000-8000-000000000011
      00000000-0000-4000-8000-000000000012
    ]
    -> { values.shift || "00000000-0000-4000-8000-000000000099" }
  end

  def submission
    @submission ||= Hive::Proposals::SourceEvent.submission(
      source_event_id: "pse-#{'a' * 64}", proposal_id: proposal_id,
      proposal_binding: proposal_binding(evaluator: nil), task_binding: task_binding,
      proposed_change: "Use a stricter review prompt", motivation: "Improve recall",
      evidence: [ evidence ], created_at: "2026-08-30T12:00:00Z"
    )
  end

  def evaluation
    @evaluation ||= Hive::Proposals::SourceEvent.evaluation(
      source_event_id: "pse-#{'b' * 64}", proposal_id: proposal_id,
      proposal_binding: proposal_binding(evaluator: evaluator), task_binding: task_binding,
      method: { "kind" => "benchmark", "label" => "held-out recall" },
      result: { "outcome" => "pass", "metrics" => { "recall" => 0.91 } },
      rationale: "No protected regression", evidence: [ evidence ], links: [],
      created_at: "2026-08-30T12:05:00Z"
    )
  end

  def proposal_id = "prp-00000000-0000-4000-8000-000000000001"

  def proposal_binding(evaluator:)
    {
      "schema_version" => 1,
      "subject" => {
        "kind" => "skill", "reference" => "agent-skills/reviewer",
        "revision" => "v2", "proposal_id" => proposal_id
      },
      "actor" => { "id" => "alice", "kind" => "proposer", "binding" => "team:skills" },
      "evaluator" => evaluator, "configuration_fingerprint" => "c" * 64,
      "policy" => {
        "visibility" => "project", "retention" => "project",
        "allowed_link_schemes" => [ "https" ]
      }
    }
  end

  def evaluator
    {
      "id" => "benchmark-reviewer", "fingerprint" => "d" * 64,
      "configuration_fingerprint" => "c" * 64,
      "admission" => {
        "workflows" => [ "coding" ], "stages" => [ "4-execute" ],
        "agent_profiles" => [ "codex" ]
      }
    }
  end

  def task_binding
    {
      "project" => "hive", "task_id" => "43059", "task_slug" => "proposal-task",
      "workflow_id" => "coding", "stage" => "4-execute", "task_generation" => 1,
      "ownership_generation" => "owner-1", "attempt_id" => "attempt-1"
    }
  end

  def evidence
    { "label" => "benchmark", "content" => "score=0.91", "media_type" => "text/plain" }
  end
end
