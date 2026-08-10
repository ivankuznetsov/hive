require "hive/workflow"

module Hive
  module Workflows
    module Content
      BUDGET_USD = {
        "research" => 3.0,
        "outline" => 1.5,
        "draft" => 3.0,
        "critique" => 2.0,
        "done" => 2.0
      }.freeze

      DESCRIPTOR = Hive::Workflow.new(
        id: :content,
        archive_visibility_retention_days: 3,
        stages: [
          Hive::Workflow::Stage.new(
            name: "inbox",
            index: 1,
            state_file: "idea.md",
            kind: :inert
          ),
          Hive::Workflow::Stage.new(
            name: "research",
            index: 2,
            state_file: "research.md",
            advance_verb: Hive::Workflow::AdvanceVerb.new(name: "research"),
            kind: :agent,
            skill: "/deep-research",
            status_mode: :state_file_marker,
            budget_usd: BUDGET_USD.fetch("research"),
            timeout_sec: 1800
          ),
          Hive::Workflow::Stage.new(
            name: "outline",
            index: 3,
            state_file: "outline.md",
            advance_verb: Hive::Workflow::AdvanceVerb.new(name: "outline"),
            kind: :agent,
            skill: "/seo:research",
            status_mode: :state_file_marker,
            budget_usd: BUDGET_USD.fetch("outline"),
            timeout_sec: 600
          ),
          Hive::Workflow::Stage.new(
            name: "draft",
            index: 4,
            state_file: "draft.md",
            advance_verb: Hive::Workflow::AdvanceVerb.new(name: "draft"),
            kind: :agent,
            skill: "/write:writer",
            status_mode: :state_file_marker,
            budget_usd: BUDGET_USD.fetch("draft"),
            timeout_sec: 1200
          ),
          Hive::Workflow::Stage.new(
            name: "critique",
            index: 5,
            state_file: "critique.md",
            advance_verb: Hive::Workflow::AdvanceVerb.new(name: "critique"),
            kind: :agent,
            skill: "/write:editor",
            status_mode: :state_file_marker,
            budget_usd: BUDGET_USD.fetch("critique"),
            timeout_sec: 900
          ),
          Hive::Workflow::Stage.new(
            name: "done",
            index: 6,
            state_file: "article.md",
            advance_verb: Hive::Workflow::AdvanceVerb.new(name: "done"),
            kind: :agent,
            skill: "/write:writer",
            status_mode: :state_file_marker,
            budget_usd: BUDGET_USD.fetch("done"),
            timeout_sec: 900
          )
        ]
      )
    end
  end
end
