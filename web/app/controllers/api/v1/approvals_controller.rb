# frozen_string_literal: true

module Api
  module V1
    class ApprovalsController < MutationsController
      def create
        project = authorized_project!("answer")
        input = mutation_input!(allowed: %w[stage generation], required: %w[stage generation])
        malformed! unless input.fetch("stage").match?(Hive::Remote::Contract::STAGE) &&
          input.fetch("generation").match?(Hive::Remote::Contract::GENERATION)
        existing = existing_operation(project)
        _, task = resolve_target!(validate_state: !existing)
        result = command_service.approve(project: project, task: task, stage: input.fetch("stage"),
          generation: input.fetch("generation"), **command_authority)
        render_acknowledgement(result)
      end
    end
  end
end
