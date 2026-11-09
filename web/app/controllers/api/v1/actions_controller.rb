# frozen_string_literal: true

module Api
  module V1
    class ActionsController < MutationsController
      def create
        project = authorized_project!("act")
        input = mutation_input!(allowed: %w[action_id observation], required: %w[action_id observation])
        existing = existing_operation(project)
        _, task = resolve_target!(validate_state: !existing)
        result = command_service.action(project: project, task: task, action_id: input.fetch("action_id"),
          observation: input.fetch("observation"), **command_authority)
        render_acknowledgement(result)
      end
    end
  end
end
