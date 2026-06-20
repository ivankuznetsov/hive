require "test_helper"
require "hive/cli"
require "hive/workflows"

# Direct coverage for Hive::Workflows. The workflow verb map is the
# single source of truth for `hive brainstorm/plan/develop/review/pr/
# archive`; a typo here silently misroutes a verb to the wrong source
# or target stage. Pin every public surface so a future refactor /
# rebase can't drift the contract without breaking this file.
class WorkflowsTest < Minitest::Test
  def test_verbs_has_canonical_keys_in_order
    assert_equal %w[brainstorm plan develop open-pr review artifacts finalize archive],
                 Hive::Workflows::VERBS.keys,
                 "VERBS must list the canonical workflow verbs"
    assert_equal 8, Hive::Workflows::VERBS.size
  end

  def test_every_workflow_verb_has_thor_command
    missing = Hive::Workflows::VERBS.keys.reject do |verb|
      Hive::CLI.all_commands.key?(verb) || Hive::CLI.map.key?(verb)
    end
    assert_empty missing,
                 "workflow verbs must be callable through the Thor CLI"
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
    assert_equal "7-artifacts", cfg[:source]
    assert_equal "8-finalize", cfg[:target]
  end

  def test_archive_verb_source_and_target
    cfg = Hive::Workflows::VERBS.fetch("archive")
    assert_equal "8-finalize", cfg[:source]
    assert_equal "9-done", cfg[:target]
  end

  def test_artifacts_verb_source_and_target
    cfg = Hive::Workflows::VERBS.fetch("artifacts")
    assert_equal "6-review", cfg[:source]
    assert_equal "7-artifacts", cfg[:target]
  end

  # ── verb_advancing_from ───────────────────────────────────────────────

  def test_verb_advancing_from_4_execute_is_open_pr
    assert_equal "open-pr", Hive::Workflows.verb_advancing_from("4-execute")
  end

  def test_verb_advancing_from_6_review_is_finalize
    assert_equal "artifacts", Hive::Workflows.verb_advancing_from("6-review")
  end

  def test_verb_advancing_from_9_done_is_nil
    assert_nil Hive::Workflows.verb_advancing_from("9-done"),
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

  # ── next_dir_after ────────────────────────────────────────────────────

  def test_next_dir_after_6_review_is_7_artifacts
    assert_equal "7-artifacts", Hive::Workflows.next_dir_after("6-review")
  end

  def test_next_dir_after_7_artifacts_is_8_finalize
    assert_equal "8-finalize", Hive::Workflows.next_dir_after("7-artifacts")
  end

  def test_next_dir_after_terminal_is_nil
    assert_nil Hive::Workflows.next_dir_after("9-done"),
               "no stage follows the terminal stage"
  end

  def test_next_dir_after_unknown_stage_is_nil
    assert_nil Hive::Workflows.next_dir_after("99-imaginary"),
               "unknown stage dirs surface as nil so callers can branch on absence"
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

  def test_all_stage_dirs_and_names_default_to_coding_descriptor
    assert_equal Hive::Workflows::Registry.default.stage_dirs, Hive::Workflows.all_stage_dirs
    assert_equal Hive::Workflows::Registry.default.stage_names, Hive::Workflows.all_stage_names
  end

  def test_all_stage_dirs_and_names_include_registered_workflows
    with_registered_workflow(research_workflow) do
      assert_includes Hive::Workflows.all_stage_dirs, "2-gather"
      assert_includes Hive::Workflows.all_stage_names, "gather"
      assert_includes Hive::Workflows.all_stage_dirs, "3-plan"
      assert_includes Hive::Workflows.all_stage_names, "plan"
    end
  end

  def test_resolve_stage_ref_across_workflows_rejects_ambiguous_refs
    descriptor = Hive::Workflow.new(
      id: :alternate_plan,
      stages: [
        Hive::Workflow::Stage.new(name: "plan", index: 1, state_file: "plan.md", kind: :agent)
      ]
    )

    with_registered_workflow(descriptor) do
      error = assert_raises(Hive::InvalidTaskPath) do
        Hive::Workflows.resolve_stage_ref_across_workflows("plan")
      end

      assert_includes error.message, "ambiguous stage 'plan'"
      assert_includes error.message, "3-plan"
      assert_includes error.message, "1-plan"
    end
  end
end
