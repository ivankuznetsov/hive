require "test_helper"
require "hive/conditions/generation_tracker"

class ConditionsGenerationTrackerTest < Minitest::Test
  include HiveTestHelper

  FakeTask = Struct.new(:folder, :state_file, keyword_init: true)

  def test_inputs_decisions_and_policy_advance_while_outputs_and_restarts_do_not
    with_tmp_dir do |dir|
      task = FakeTask.new(folder: dir, state_file: File.join(dir, "task.md"))
      File.write(File.join(dir, "plan.md"), "plan one\n")
      File.write(task.state_file, "<!-- EXECUTE_WAITING -->\n")
      tracker = Hive::Conditions::GenerationTracker.new

      first = tracker.resolve(task: task, records: [], workflow_policy: { "version" => 1 })
      assert_equal 1, first.task_generation
      records = [ generation_record(first) ]

      File.write(task.state_file, "<!-- EXECUTE_COMPLETE -->\n")
      File.write(File.join(dir, "worktree.yml"), "output: changed\n")
      retry_decision = tracker.resolve(task: task, records: records, workflow_policy: { "version" => 1 })
      assert_equal 1, retry_decision.task_generation
      refute retry_decision.advanced

      File.write(File.join(dir, "plan.md"), "plan two\n")
      input_change = tracker.resolve(task: task, records: records, workflow_policy: { "version" => 1 })
      assert_equal 2, input_change.task_generation

      decision_change = tracker.resolve(
        task: task, records: records, workflow_policy: { "version" => 1 },
        operator_decisions: [ { "answer" => "approved" } ]
      )
      assert_equal 2, decision_change.task_generation

      policy_change = tracker.resolve(task: task, records: records, workflow_policy: { "version" => 2 })
      assert_equal 2, policy_change.task_generation
    end
  end

  def test_explicit_repair_and_invalidation_tokens_increment_once
    with_tmp_dir do |dir|
      task = FakeTask.new(folder: dir, state_file: File.join(dir, "task.md"))
      File.write(File.join(dir, "plan.md"), "plan\n")
      tracker = Hive::Conditions::GenerationTracker.new
      first = tracker.resolve(task: task, records: [])
      records = [ generation_record(first) ]

      repair = tracker.resolve(
        task: task, records: records, reason: "fenced_repair", invalidation_token: "repair-1"
      )
      assert_equal 2, repair.task_generation
      records << generation_record(repair)
      repeated = tracker.resolve(
        task: task, records: records, reason: "fenced_repair", invalidation_token: "repair-1"
      )
      assert_equal 2, repeated.task_generation
      refute repeated.advanced

      invalidated = tracker.resolve(
        task: task, records: records, reason: "workflow_invalidation", invalidation_token: "policy-2"
      )
      assert_equal 3, invalidated.task_generation
    end
  end

  def test_commit_generation_changes_only_for_exact_head_changes
    tracker = Hive::Conditions::GenerationTracker.new
    first = tracker.commit(records: [], task_generation: 1, head_sha: "a" * 40, branch: "feature")
    assert_equal 1, first.commit_generation
    assert first.advanced
    records = [ commit_record(first) ]

    same = tracker.commit(records: records, task_generation: 1, head_sha: "a" * 40, branch: "feature")
    assert_equal 1, same.commit_generation
    refute same.advanced

    changed = tracker.commit(records: records, task_generation: 1, head_sha: "b" * 40, branch: "feature")
    assert_equal 2, changed.commit_generation
    assert changed.advanced

    missing = tracker.commit(records: records, task_generation: 1, head_sha: nil, branch: nil)
    assert_equal 1, missing.commit_generation
    refute missing.advanced
  end

  private

  def generation_record(decision)
    record(
      "event_type" => "generation_advanced",
      "task_generation" => decision.task_generation,
      "commit_generation" => 0,
      "reason" => decision.reason,
      "payload" => {
        "input_fingerprint" => decision.input_fingerprint,
        "invalidation_token" => decision.invalidation_token
      }
    )
  end

  def commit_record(decision)
    record(
      "event_type" => "commit_generation_advanced",
      "task_generation" => 1,
      "commit_generation" => decision.commit_generation,
      "payload" => { "head_sha" => decision.head_sha, "branch" => decision.branch }
    )
  end

  def record(overrides)
    {
      "schema" => Hive::TaskJournal::Envelope::SCHEMA,
      "schema_version" => 1,
      "event_id" => SecureRandom.uuid,
      "event_type" => "generation_advanced",
      "occurred_at" => "2026-07-17T12:00:00Z",
      "task_generation" => 1,
      "commit_generation" => 0,
      "payload" => {}
    }.merge(overrides)
  end
end
