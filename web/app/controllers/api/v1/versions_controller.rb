# frozen_string_literal: true

module Api
  module V1
    class VersionsController < BaseController
      def not_found
        render_error(404, "not_found", "resource not found")
      end
    end
  end
end
