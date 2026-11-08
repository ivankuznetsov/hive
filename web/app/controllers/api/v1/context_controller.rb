# frozen_string_literal: true

module Api
  module V1
    class ContextController < BaseController
      def show
        token = authority.token
        render_data({
          "instance_id" => instance_id, "api_version" => "v1",
          "token" => token.slice("id", "name", "scopes", "all_projects", "expires_at").merge(
            "projects" => token.fetch("projects").map { |row| row.fetch("name") }
          )
        })
      end
    end
  end
end
