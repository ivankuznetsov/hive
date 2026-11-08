# frozen_string_literal: true

require "hive/remote/operation_projection"

module Api
  module V1
    class OperationsController < BaseController
      def show
        project = authorized_project!
        data = Hive::Remote::OperationProjection.new.call(project: project, id: params.fetch(:id),
          principal: authority.principal, scopes: authority.token.fetch("scopes"))
        render_bounded(data)
      end
    end
  end
end
