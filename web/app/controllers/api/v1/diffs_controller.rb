# frozen_string_literal: true

module Api
  module V1
    class DiffsController < BaseController
      def show
        project, task = read_target!(validate_state: false)
        cap = response_limit(Hive::Remote::Contract::MAX_CONTENT_BYTES)
        render_bounded(serializers.diff(read_service.diff(project: project, task: task, max_bytes: cap)), limit: cap)
      end
    end
  end
end
