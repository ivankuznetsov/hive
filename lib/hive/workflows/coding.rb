require "hive/conditions/policy"
require "hive/workflow"

module Hive
  module Workflows
    module Coding
      # Per-stage user-facing action keys for coding's `:agent`/`:inert`
      # descriptor stages, consumed by `TaskAction#coding_table_action`. This
      # table covers ONLY those stages — coding's runtime-kind stages
      # (`:execute`, `:review_council`, `:finalize`) are classified by their
      # own helpers in `task_action.rb` and are deliberately absent here.
      ACTION_DISPATCH = {
        "inbox" => {
          kind: :inert,
          default: :inbox
        },
        "brainstorm" => {
          kind: :agent,
          handler: :brainstorm_action
        },
        "plan" => {
          kind: :agent,
          handler: :plan_action
        },
        "open-pr" => {
          kind: :agent,
          complete: :open_pr_complete,
          default: :open_pr_ready
        },
        "artifacts" => {
          kind: :agent,
          complete: :artifacts_complete,
          default: :artifacts_ready
        },
        "done" => {
          kind: :inert,
          default: :done
        }
      }.freeze

      DESCRIPTOR = Hive::Workflow.new(
        id: :coding,
        archive_visibility_retention_days: 3,
        stages: [
          Hive::Workflow::Stage.new(
            name: "inbox",
            index: 1,
            state_file: "idea.md",
            kind: :inert
          ),
          Hive::Workflow::Stage.new(
            name: "brainstorm",
            index: 2,
            state_file: "brainstorm.md",
            advance_verb: Hive::Workflow::AdvanceVerb.new(name: "brainstorm", force_source: true),
            kind: :agent,
            skill: "/ce-brainstorm",
            status_mode: :state_file_marker,
            budget_usd: 50,
            timeout_sec: 1800
          ),
          Hive::Workflow::Stage.new(
            name: "plan",
            index: 3,
            state_file: "plan.md",
            advance_verb: Hive::Workflow::AdvanceVerb.new(name: "plan"),
            kind: :agent,
            status_mode: :state_file_marker,
            budget_usd: 100,
            timeout_sec: 3600
          ),
          Hive::Workflow::Stage.new(
            name: "execute",
            index: 4,
            state_file: "task.md",
            advance_verb: Hive::Workflow::AdvanceVerb.new(name: "develop"),
            kind: :execute,
            status_mode: :exit_code_only,
            budget_usd: 500,
            timeout_sec: 14400,
            condition_policy: Hive::Conditions::Policy.default.rule_for("execute_to_open_pr")
          ),
          Hive::Workflow::Stage.new(
            name: "open-pr",
            index: 5,
            state_file: "pr.md",
            advance_verb: Hive::Workflow::AdvanceVerb.new(name: "open-pr"),
            kind: :agent,
            status_mode: :state_file_marker,
            budget_usd: 50,
            timeout_sec: 1800
          ),
          Hive::Workflow::Stage.new(
            name: "review",
            index: 6,
            state_file: "task.md",
            advance_verb: Hive::Workflow::AdvanceVerb.new(name: "review"),
            kind: :review_council
          ),
          Hive::Workflow::Stage.new(
            name: "artifacts",
            index: 7,
            state_file: "artifact.md",
            advance_verb: Hive::Workflow::AdvanceVerb.new(name: "artifacts"),
            kind: :agent,
            status_mode: :state_file_marker,
            budget_usd: 100,
            timeout_sec: 3600
          ),
          Hive::Workflow::Stage.new(
            name: "finalize",
            index: 8,
            state_file: "pr.md",
            advance_verb: Hive::Workflow::AdvanceVerb.new(name: "finalize"),
            kind: :finalize,
            status_mode: :state_file_marker,
            budget_usd: 50,
            timeout_sec: 1800
          ),
          Hive::Workflow::Stage.new(
            name: "done",
            index: 9,
            state_file: "task.md",
            advance_verb: Hive::Workflow::AdvanceVerb.new(name: "archive"),
            kind: :inert
          )
        ]
      )
    end
  end
end
