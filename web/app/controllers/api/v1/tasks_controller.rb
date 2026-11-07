# frozen_string_literal: true

module Api
  module V1
    class TasksController < BaseController
      def show
        project, task = read_target!
        data = serializers.task(read_service.task(project: project, task: task))
        data["approval_generation"] = Hive::Remote::CommandService.generation_for(task, project: project.fetch("name"))
        descriptor = read_service.action(project: project, task: task)
        if descriptor && authority.token.fetch("scopes").include?("act")
          begin
            row = Hive::OperationalAction.observed_row(task, project: project.fetch("name"))
            effect = Hive::Remote::CommandService.effect_for(task: task, row: row,
              action_id: descriptor.fetch("action_id"), project: project)
            if effect.fetch("kind") != "approve" || authority.token.fetch("scopes").include?("answer")
              data.fetch("actions") << descriptor.slice("action_id", "target", "observation_token")
            end
          rescue Hive::OperationalActionUsageError
            # A local-only transition is never advertised as a remote action.
          end
        end
        render_bounded(data)
      end
    end
  end
end
