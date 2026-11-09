require "test_helper"
require "hive/review_residual_commit"

class ReviewResidualCommitTest < Minitest::Test
  include HiveTestHelper

  SHA = "5c7fb43e02f93ca3db5b156c4dfb5f589c3b7a86".freeze
  NOW = Time.utc(2026, 11, 9, 1, 11, 30)

  StateTask = Struct.new(:state_file)

  def marker(name, attrs = {})
    Hive::Markers::State.new(name: name, attrs: attrs, raw: nil)
  end

  def with_state(body)
    Dir.mktmpdir("hive-residual") do |dir|
      state_file = File.join(dir, "task.md")
      File.write(state_file, body)
      yield(StateTask.new(state_file))
    end
  end

  def test_annotate_stamps_residual_commit_on_review_failure_marker
    with_state("intro\n<!-- REVIEW_ERROR phase=ci reason=limits_reached marker_id=abc attempt_id=att " \
               "message=\"github CI hit a usage/credit limit\" -->\n") do |task|
      observed = Hive::Markers.current(task.state_file)

      assert Hive::ReviewResidualCommit.annotate!(task, stage: "6-review", observed_marker: observed, head: SHA)

      after = Hive::Markers.current(task.state_file)
      assert_equal :review_error, after.name
      assert_equal SHA, after.attrs.fetch("residual_commit")
      assert_equal "false", after.attrs.fetch("residual_published")
      assert_equal "abc", after.attrs.fetch("marker_id")
      assert_equal "att", after.attrs.fetch("attempt_id")
      assert_equal "github CI hit a usage/credit limit; residual commit 5c7fb43e02f9 is local-only " \
                   "(not on the PR head)", after.attrs.fetch("message")
      assert File.read(task.state_file).start_with?("intro\n")
    end
  end

  def test_annotate_sets_a_message_when_the_marker_had_none
    with_state("<!-- REVIEW_STALE pass=2 -->\n") do |task|
      observed = Hive::Markers.current(task.state_file)

      assert Hive::ReviewResidualCommit.annotate!(task, stage: "6-review", observed_marker: observed, head: SHA)
      assert_equal "residual commit 5c7fb43e02f9 is local-only (not on the PR head)",
                   Hive::Markers.current(task.state_file).attrs.fetch("message")
    end
  end

  def test_annotate_ignores_other_stages_success_markers_and_missing_heads
    with_state("<!-- REVIEW_COMPLETE pass=2 -->\n") do |task|
      complete = Hive::Markers.current(task.state_file)
      error = marker(:review_error)

      refute Hive::ReviewResidualCommit.annotate!(task, stage: "6-review", observed_marker: complete, head: SHA)
      refute Hive::ReviewResidualCommit.annotate!(task, stage: "8-finalize", observed_marker: error, head: SHA)
      refute Hive::ReviewResidualCommit.annotate!(task, stage: "6-review", observed_marker: nil, head: SHA)
      refute Hive::ReviewResidualCommit.annotate!(task, stage: "6-review", observed_marker: error, head: nil)
      assert_equal "<!-- REVIEW_COMPLETE pass=2 -->\n", File.read(task.state_file)
    end
  end

  def test_annotate_loses_to_a_concurrent_marker_write
    with_state("<!-- REVIEW_ERROR phase=fix reason=agent_crashed -->\n") do |task|
      observed = Hive::Markers.current(task.state_file)
      File.write(task.state_file, "<!-- REVIEW_WORKING pass=3 -->\n")

      refute Hive::ReviewResidualCommit.annotate!(task, stage: "6-review", observed_marker: observed, head: SHA)
      assert_equal "<!-- REVIEW_WORKING pass=3 -->\n", File.read(task.state_file)
    end
  end

  def test_next_step_names_the_commit_and_both_operator_choices
    hint = Hive::ReviewResidualCommit.next_step(
      marker(:review_error, "residual_commit" => SHA, "residual_published" => "false"), worktree: "/wt"
    )

    assert_includes hint, "residual commit #{SHA} in /wt"
    assert_includes hint, "NOT on the PR"
    assert_includes hint, "`git -C /wt show #{SHA}`"
    assert_includes hint, "re-run review"
    assert_includes hint, "`git -C /wt reset --keep #{SHA}^`"

    bare = Hive::ReviewResidualCommit.next_step(
      marker(:review_error, "residual_commit" => SHA, "residual_published" => "false"), worktree: nil
    )
    assert_includes bare, "in the task worktree"
    assert_includes bare, "`git show #{SHA}`"
  end

  def test_next_step_is_nil_without_an_unpublished_residual_commit
    assert_nil Hive::ReviewResidualCommit.next_step(marker(:review_error), worktree: "/wt")
    assert_nil Hive::ReviewResidualCommit.next_step(
      marker(:review_error, "residual_commit" => SHA, "residual_published" => "true"), worktree: "/wt"
    )
  end

  def test_agent_profile_hint_points_long_fix_and_ci_limits_at_the_role_config_key
    ci = marker(:review_error, "phase" => "ci", "reason" => "limits_reached", "limit_source" => "agent",
                               "retry_after" => "2026-11-11T10:26:00Z")
    fix = marker(:review_error, "phase" => "fix", "reason" => "limits_reached",
                                "retry_after" => "2026-11-10T01:00:00Z")

    ci_hint = Hive::ReviewResidualCommit.agent_profile_hint(ci, now: NOW)
    assert_includes ci_hint, "resets at 2026-11-11T10:26:00Z"
    assert_includes ci_hint, "`review.ci.agent`"
    assert_includes Hive::ReviewResidualCommit.agent_profile_hint(fix, now: NOW), "`review.fix.agent`"
  end

  def test_agent_profile_hint_skips_short_hosted_unrelated_and_malformed_limits
    base = { "phase" => "ci", "reason" => "limits_reached", "retry_after" => "2026-11-11T10:26:00Z" }
    cases = [
      base.merge("retry_after" => "2026-11-09T05:00:00Z"),
      base.merge("limit_source" => "hosted_ci"),
      base.merge("phase" => "reviewers"),
      base.merge("reason" => "agent_crashed"),
      base.merge("retry_after" => "not-a-time")
    ]

    cases.each do |attrs|
      assert_nil Hive::ReviewResidualCommit.agent_profile_hint(marker(:review_error, attrs), now: NOW), attrs.inspect
    end
  end
end
