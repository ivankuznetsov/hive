require "test_helper"
require "json"
require "hive/refactor_patrol/post_merge_state_store"

class HiveRefactorPatrolPostMergeStateStoreTest < Minitest::Test
  include HiveTestHelper

  T0 = Time.utc(2026, 7, 15, 12, 0, 0)

  def merge(pr, sha, base)
    {
      "pr_number" => pr,
      "merge_sha" => sha,
      "base_sha" => base,
      "subject" => "Change #{pr} (##{pr})",
      "changed_paths" => [ "lib/change_#{pr}.rb" ]
    }
  end

  def store(root, project: "hive")
    Hive::RefactorPatrol::PostMergeStateStore.new(root, project: project)
  end

  def test_first_initialization_sets_non_retroactive_baseline_and_soft_diagnostic
    with_tmp_dir do |dir|
      state = store(dir).initialize_at!(
        head_sha: "head-a",
        now: T0,
        capability_merge_sha: "d98e50a5",
        capability_merge_ancestor: true
      )

      assert_equal "head-a", state.fetch("initial_sha")
      assert_equal "head-a", state.fetch("checkpoint_sha")
      assert_nil state.fetch("active_batch_head")
      assert_empty state.fetch("merges")
      assert_equal true, state.dig("diagnostics", "capability_merge_ancestor")
    end
  end

  def test_failed_attempt_remains_owed_and_keeps_original_fingerprint_baseline_after_reload
    with_tmp_dir do |dir|
      state = store(dir)
      state.initialize_at!(head_sha: "base", now: T0)
      state.open_batch!(head_sha: "merge-1", merges: [ merge(1, "merge-1", "base") ], now: T0 + 1)
      identity = state.identity_for(1, "merge-1")

      state.reserve!(identity, fingerprint_snapshot: { "known" => { "state" => "seen" } }, now: T0 + 2)
      state.record_failure!(identity, reason: "child interrupted", evidence: { "signal" => "TERM" }, now: T0 + 3)

      reloaded = store(dir)
      record = reloaded.owed_merges.fetch(0)
      assert_equal identity, record.fetch("identity")
      assert_equal({ "known" => { "state" => "seen" } }, record.fetch("fingerprint_snapshot"))
      assert_equal "failed", record.fetch("attempts").last.fetch("status")

      reloaded.reserve!(identity, fingerprint_snapshot: { "later" => {} }, now: T0 + 4)
      assert_equal({ "known" => { "state" => "seen" } }, reloaded.merge_record(identity).fetch("fingerprint_snapshot"))
    end
  end

  def test_later_success_does_not_advance_checkpoint_past_blocked_gap
    with_tmp_dir do |dir|
      state = store(dir)
      state.initialize_at!(head_sha: "base", now: T0)
      state.open_batch!(
        head_sha: "batch-head",
        merges: [ merge(1, "merge-1", "base"), merge(2, "merge-2", "merge-1") ],
        now: T0 + 1
      )
      first = state.identity_for(1, "merge-1")
      second = state.identity_for(2, "merge-2")

      state.reserve!(first, fingerprint_snapshot: {}, now: T0 + 2)
      state.record_blocked!(first, reason: "checkout_dirty", now: T0 + 3)
      state.reserve!(second, fingerprint_snapshot: {}, now: T0 + 4)
      state.complete!(second, report: successful_report(2, "merge-2", "merge-1"), emission_digests: {}, now: T0 + 5)

      assert_equal "base", state.state.fetch("checkpoint_sha")
      assert_equal "processed", state.merge_record(second).fetch("status")
      refute_includes state.owed_merges.map { |item| item.fetch("identity") }, second

      state.reopen_blocked!(now: T0 + 6)
      state.reserve!(first, fingerprint_snapshot: {}, now: T0 + 7)
      state.complete!(first, report: successful_report(1, "merge-1", "base"), emission_digests: {}, now: T0 + 8)

      assert_equal "batch-head", state.state.fetch("checkpoint_sha")
      assert_nil state.state.fetch("active_batch_head")
    end
  end

  def test_reload_reconciles_report_and_emission_ledger_after_split_completion
    with_tmp_dir do |dir|
      state = store(dir)
      state.initialize_at!(head_sha: "base", now: T0)
      state.open_batch!(head_sha: "merge-1", merges: [ merge(1, "merge-1", "base") ], now: T0 + 1)
      identity = state.identity_for(1, "merge-1")
      state.reserve!(identity, fingerprint_snapshot: {}, now: T0 + 2)

      report = successful_report(1, "merge-1", "base").merge(
        "emitted_delta" => [ { "fingerprint" => "fp-1", "bucket" => "accepted", "content_digest" => "digest-1" } ]
      )
      state.persist_artifacts!(identity, report: report, emission_digests: { "fp-1" => "digest-1" })

      raw = JSON.parse(File.read(File.join(state.root, "state.json")))
      assert_equal "running", raw.fetch("merges").first.fetch("status"), "simulated crash must precede processed state write"

      reloaded = store(dir)
      assert_equal "processed", reloaded.merge_record(identity).fetch("status")
      assert_equal "merge-1", reloaded.state.fetch("checkpoint_sha")
      assert_empty reloaded.owed_merges
      assert_equal [ "fp-1" ], reloaded.emissions.fetch(identity).fetch("digests").keys
    end
  end

  def test_malformed_newer_identity_mismatch_and_unreachable_checkpoint_fail_closed
    with_tmp_dir do |dir|
      state = store(dir)
      state.initialize_at!(head_sha: "base", now: T0)
      path = File.join(state.root, "state.json")

      File.write(path, "[")
      assert_raises(Hive::RefactorPatrol::PostMergeStateStore::StateError) { store(dir).state }

      File.write(path, JSON.pretty_generate(valid_state(dir).merge("schema_version" => 2)))
      assert_raises(Hive::RefactorPatrol::PostMergeStateStore::StateError) { store(dir).state }

      File.write(path, JSON.pretty_generate(valid_state(dir).merge("project" => "other")))
      assert_raises(Hive::RefactorPatrol::PostMergeStateStore::StateError) { store(dir).state }

      File.write(path, JSON.pretty_generate(valid_state(dir)))
      assert_raises(Hive::RefactorPatrol::PostMergeStateStore::StateError) do
        store(dir).load!(head_sha: "head", ancestor_check: ->(_checkpoint, _head) { false })
      end
    end
  end

  private

  def successful_report(pr, merge_sha, base_sha)
    {
      "schema" => "hive-refactor-patrol-post-merge",
      "schema_version" => 1,
      "completion_status" => "success",
      "project" => "hive",
      "project_root" => nil,
      "pr_number" => pr,
      "merge_sha" => merge_sha,
      "base_sha" => base_sha,
      "analysis_sha" => merge_sha,
      "changed_paths" => [ "lib/change_#{pr}.rb" ],
      "scope" => { "kind" => "path", "values" => [ "lib" ], "fallback" => false },
      "totals" => { "accepted" => 0, "flagged" => 0, "suppressed" => 0 },
      "flagged_theses" => [],
      "emitted_delta" => [],
      "started_at" => T0.utc.iso8601,
      "completed_at" => (T0 + 1).utc.iso8601
    }
  end

  def valid_state(dir)
    {
      "schema_version" => 1,
      "project" => "hive",
      "project_root" => File.realpath(dir),
      "initial_sha" => "base",
      "checkpoint_sha" => "base",
      "active_batch_head" => nil,
      "active_batch_start_index" => nil,
      "initialized_at" => T0.utc.iso8601,
      "updated_at" => T0.utc.iso8601,
      "merges" => [],
      "diagnostics" => {}
    }
  end
end
