require "hive/patrol_fix"
require "hive/workflow"

module Hive
  module Workflows
    module PatrolFix
      STAGES = %w[inbox fix validate review publish done].freeze

      DESCRIPTOR = Hive::Workflow.new(
        id: Hive::PatrolFix::WORKFLOW_ID,
        controller: :patrol_fix,
        archive_visibility_retention_days: :never,
        result: Hive::Workflow::Result.new(
          kind: :change,
          capabilities: %i[worktree diff publication supporting_artifacts]
        ),
        stages: STAGES.each_with_index.map do |name, index|
          Hive::Workflow::Stage.new(
            name: name,
            index: index + 1,
            state_file: Hive::PatrolFix::TaskManifest::FILENAME,
            kind: name == "done" ? :inert : :controller,
            # Every stage — including the terminal inert one — executes through
            # the workflow-owned controller runner. The explicit pin keeps
            # dispatch descriptor-owned even where the kind derives no strategy.
            runner: :controller
          )
        end
      )
    end
  end
end
