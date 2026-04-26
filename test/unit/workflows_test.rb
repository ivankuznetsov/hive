require "test_helper"
require "hive/workflows"

# Direct coverage for Hive::Workflows. The workflow verb map is the
# single source of truth for `hive brainstorm/plan/develop/review/pr/
# archive`; a typo here silently misroutes a verb to the wrong source
# or target stage. Pin every public surface so a future refactor /
# rebase can't drift the contract without breaking this file.
class WorkflowsTest < Minitest::Test
  def test_verbs_has_exactly_six_keys_in_canonical_order
    assert_equal %w[brainstorm plan develop review pr archive],
                 Hive::Workflows::VERBS.keys,
                 "VERBS must list the canonical six workflow verbs"
    assert_equal 6, Hive::Workflows::VERBS.size
  end

  def test_review_verb_post_rebase_source_and_target
    cfg = Hive::Workflows::VERBS.fetch("review")
    assert_equal "4-execute", cfg[:source],
                 "review advances OUT of 4-execute"
    assert_equal "5-review", cfg[:target],
                 "review arrives AT 5-review (the new stage)"
  end

  def test_pr_verb_post_rebase_source_shifts_to_5_review
    cfg = Hive::Workflows::VERBS.fetch("pr")
    assert_equal "5-review", cfg[:source],
                 "pr's source shifted from 4-execute to 5-review post-rebase"
    assert_equal "6-pr", cfg[:target]
  end

  def test_archive_verb_post_rebase_source_and_target_shift
    cfg = Hive::Workflows::VERBS.fetch("archive")
    assert_equal "6-pr", cfg[:source],
                 "archive's source shifted from 5-pr to 6-pr post-rebase"
    assert_equal "7-done", cfg[:target],
                 "archive's target shifted from 6-done to 7-done post-rebase"
  end

  # ── verb_advancing_from ───────────────────────────────────────────────

  def test_verb_advancing_from_4_execute_is_review
    assert_equal "review", Hive::Workflows.verb_advancing_from("4-execute")
  end

  def test_verb_advancing_from_5_review_is_pr
    assert_equal "pr", Hive::Workflows.verb_advancing_from("5-review")
  end

  def test_verb_advancing_from_7_done_is_nil
    assert_nil Hive::Workflows.verb_advancing_from("7-done"),
               "no verb advances out of the terminal stage"
  end

  # ── verb_arriving_at ──────────────────────────────────────────────────

  def test_verb_arriving_at_5_review_is_review
    assert_equal "review", Hive::Workflows.verb_arriving_at("5-review")
  end

  def test_verb_arriving_at_1_inbox_is_nil
    assert_nil Hive::Workflows.verb_arriving_at("1-inbox"),
               "no verb arrives at 1-inbox; tasks are seeded via `hive new`"
  end

  # ── workflow_verb? ────────────────────────────────────────────────────

  def test_workflow_verb_recognises_review
    assert Hive::Workflows.workflow_verb?("review")
  end

  def test_workflow_verb_rejects_unknown_string
    refute Hive::Workflows.workflow_verb?("approve"),
           "approve is a separate command, not a workflow verb"
  end

  # ── for_verb ──────────────────────────────────────────────────────────

  def test_for_verb_review_returns_source_and_target
    cfg = Hive::Workflows.for_verb("review")
    assert_equal "4-execute", cfg[:source]
    assert_equal "5-review", cfg[:target]
  end
end
