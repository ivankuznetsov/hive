require "hive/patrol_fix"
require "hive/workflow"

module Hive
  module Workflows
    module PatrolFix
      STAGES = %w[inbox fix validate review publish done].freeze

      DESCRIPTOR = Hive::Workflow.new(
        id: Hive::PatrolFix::WORKFLOW_ID,
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
            kind: name == "done" ? :inert : :agent
          )
        end
      )
    end
  end
end
