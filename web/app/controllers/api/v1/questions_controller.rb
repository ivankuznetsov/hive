# frozen_string_literal: true

module Api
  module V1
    class QuestionsController < BaseController
      def index
        project, task = read_target!
        inventory = read_service.questions(project: project, task: task)
        slots = handles.issue(project: project, task: task, inventory: inventory)
        render_bounded(serializers.questions(inventory, slots))
      end
    end
  end
end
