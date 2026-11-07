# frozen_string_literal: true

module Api
  module V1
    class LogsController < BaseController
      def show
        project, task = read_target!
        cap = response_limit(Hive::Remote::Contract::MAX_LOG_BYTES)
        render_bounded(serializers.log(read_service.logs(project: project, task: task, max_bytes: cap)), limit: cap)
      end
    end
  end
end
