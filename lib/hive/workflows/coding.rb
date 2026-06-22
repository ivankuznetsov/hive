require "hive/workflow"

module Hive
  module Workflows
    module Coding
      DESCRIPTOR = Hive::Workflow.new(
        id: :coding,
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
            kind: :marker,
            status_mode: :exit_code_only,
            budget_usd: 500,
            timeout_sec: 14400
          ),
          Hive::Workflow::Stage.new(
            name: "open-pr",
            index: 5,
            state_file: "pr.md",
            advance_verb: Hive::Workflow::AdvanceVerb.new(name: "open-pr"),
            kind: :marker,
            status_mode: :state_file_marker,
            budget_usd: 50,
            timeout_sec: 1800
          ),
          Hive::Workflow::Stage.new(
            name: "review",
            index: 6,
            state_file: "task.md",
            advance_verb: Hive::Workflow::AdvanceVerb.new(name: "review"),
            kind: :marker
          ),
          Hive::Workflow::Stage.new(
            name: "artifacts",
            index: 7,
            state_file: "artifact.md",
            advance_verb: Hive::Workflow::AdvanceVerb.new(name: "artifacts"),
            kind: :marker,
            status_mode: :state_file_marker,
            budget_usd: 100,
            timeout_sec: 3600
          ),
          Hive::Workflow::Stage.new(
            name: "finalize",
            index: 8,
            state_file: "pr.md",
            advance_verb: Hive::Workflow::AdvanceVerb.new(name: "finalize"),
            kind: :marker,
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
