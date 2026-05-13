require "test_helper"
require "hive/workflows"

# Direct coverage for Hive::Workflows. The workflow verb map is the
# single source of truth for `hive brainstorm/plan/develop/review/pr/
# archive`; a typo here silently misroutes a verb to the wrong source
# or target stage. Pin every public surface so a future refactor /
# rebase can't drift the contract without breaking this file.
class WorkflowsTest < Minitest::Test
  def test_verbs_has_canonical_keys_in_order
    assert_equal %w[brainstorm plan develop open-pr review finalize archive],
                 Hive::Workflows::VERBS.keys,
                 "VERBS must list the canonical workflow verbs"
    assert_equal 7, Hive::Workflows::VERBS.size
  end

  def test_open_pr_verb_source_and_target
    cfg = Hive::Workflows::VERBS.fetch("open-pr")
    assert_equal "4-execute", cfg[:source]
    assert_equal "5-open-pr", cfg[:target]
  end

  def test_review_verb_source_and_target
    cfg = Hive::Workflows::VERBS.fetch("review")
    assert_equal "5-open-pr", cfg[:source]
    assert_equal "6-review", cfg[:target]
  end

  def test_finalize_verb_source_and_target
    cfg = Hive::Workflows::VERBS.fetch("finalize")
    assert_equal "6-review", cfg[:source]
    assert_equal "7-finalize", cfg[:target]
  end

  def test_archive_verb_source_and_target
    cfg = Hive::Workflows::VERBS.fetch("archive")
    assert_equal "7-finalize", cfg[:source]
    assert_equal "8-done", cfg[:target]
  end

  # ── verb_advancing_from ───────────────────────────────────────────────

  def test_verb_advancing_from_4_execute_is_open_pr
    assert_equal "open-pr", Hive::Workflows.verb_advancing_from("4-execute")
  end

  def test_verb_advancing_from_6_review_is_finalize
    assert_equal "finalize", Hive::Workflows.verb_advancing_from("6-review")
  end

  def test_verb_advancing_from_8_done_is_nil
    assert_nil Hive::Workflows.verb_advancing_from("8-done"),
               "no verb advances out of the terminal stage"
  end

  # ── verb_arriving_at ──────────────────────────────────────────────────

  def test_verb_arriving_at_6_review_is_review
    assert_equal "review", Hive::Workflows.verb_arriving_at("6-review")
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
    assert_equal "5-open-pr", cfg[:source]
    assert_equal "6-review", cfg[:target]
  end
end
