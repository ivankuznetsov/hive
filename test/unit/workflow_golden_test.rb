require "test_helper"
require "hive/stages"
require "hive/task"
require "hive/workflows"

class WorkflowGoldenTest < Minitest::Test
  EXPECTED_DIRS = %w[
    1-inbox
    2-brainstorm
    3-plan
    4-execute
    5-open-pr
    6-review
    7-artifacts
    8-finalize
    9-done
  ].freeze

  EXPECTED_STAGE_NAMES = %w[
    inbox
    brainstorm
    plan
    execute
    open-pr
    review
    artifacts
    finalize
    done
  ].freeze

  EXPECTED_STATE_FILES = {
    "inbox" => "idea.md",
    "brainstorm" => "brainstorm.md",
    "plan" => "plan.md",
    "execute" => "task.md",
    "open-pr" => "pr.md",
    "review" => "task.md",
    "artifacts" => "artifact.md",
    "finalize" => "pr.md",
    "done" => "task.md"
  }.freeze

  EXPECTED_VERBS = {
    "brainstorm" => { source: "1-inbox", target: "2-brainstorm", force_source: true },
    "plan" => { source: "2-brainstorm", target: "3-plan" },
    "develop" => { source: "3-plan", target: "4-execute" },
    "open-pr" => { source: "4-execute", target: "5-open-pr" },
    "review" => { source: "5-open-pr", target: "6-review" },
    "artifacts" => { source: "6-review", target: "7-artifacts" },
    "finalize" => { source: "7-artifacts", target: "8-finalize" },
    "archive" => { source: "8-finalize", target: "9-done" }
  }.freeze

  def test_stage_dirs_match_original_literal
    assert_equal EXPECTED_DIRS, Hive::Stages::DIRS
    assert Hive::Stages::DIRS.frozen?
  end

  def test_task_stage_names_match_original_literal
    assert_equal EXPECTED_STAGE_NAMES, Hive::Task::STAGE_NAMES
    assert Hive::Task::STAGE_NAMES.frozen?
  end

  def test_task_state_files_match_original_literal
    assert_equal EXPECTED_STATE_FILES, Hive::Task::STATE_FILES
    assert_equal EXPECTED_STATE_FILES.to_a, Hive::Task::STATE_FILES.to_a
    assert Hive::Task::STATE_FILES.frozen?
  end

  def test_workflow_verbs_match_original_literal
    assert_equal EXPECTED_VERBS, Hive::Workflows::VERBS
    assert_equal EXPECTED_VERBS.keys, Hive::Workflows::VERBS.keys

    EXPECTED_VERBS.each do |verb, expected_entry|
      assert_equal expected_entry.keys, Hive::Workflows::VERBS.fetch(verb).keys
    end
    assert Hive::Workflows::VERBS.frozen?
  end
end
