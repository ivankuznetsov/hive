require "hive/workflow"

module Hive
  module Workflows
    module PrReview
      DESCRIPTOR = Hive::Workflow.new(
        id: :"pr-review",
        archive_visibility_retention_days: 3,
        result: Hive::Workflow::Result.new(
          kind: :change,
          capabilities: %i[worktree diff publication supporting_artifacts]
        ),
        stages: [
          Hive::Workflow::Stage.new(
            name: "review", index: 1, state_file: "task.md",
            kind: :review_council, runner: :review
          ),
          Hive::Workflow::Stage.new(
            name: "done", index: 2, state_file: "task.md",
            advance_verb: Hive::Workflow::AdvanceVerb.new(name: "archive"),
            kind: :inert, runner: :done
          )
        ]
      )
    end
  end
end
