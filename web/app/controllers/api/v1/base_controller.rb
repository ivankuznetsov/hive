# frozen_string_literal: true

require "hive/remote/token_store"
require "hive/remote/protocol"

module Api
  module V1
    class BaseController < ActionController::API
      before_action :authenticate_remote!

      rescue_from StandardError do
        render_error(503, "unavailable", "remote API is unavailable")
      end
      rescue_from Hive::Error do |error|
        status, code = case error
        when Hive::CommandConflict then [409, "conflict"]
        when Hive::CommandInProgress then [409, "in_progress"]
        when Hive::CommandUnresolved then [409, "unresolved"]
        when Hive::StaleOperationalObservation, Hive::WrongStage then [409, "stale"]
        when Hive::InvalidTaskPath then [404, "not_found"]
        when Hive::ConfigError, Hive::ConcurrentRunError then [503, "unavailable"]
        when Hive::UsageError then [400, "malformed_input"]
        else [422, "validation"]
        end
        render_error(status, code, code == "not_found" ? "resource not found" : "remote operation could not be completed")
      end
      rescue_from ActionController::ParameterMissing, ActionDispatch::Http::Parameters::ParseError do
        render_error(400, "malformed_input", "invalid request")
      end
      rescue_from Hive::Remote::Error do |error|
        render_error(error.status, error.code, error.message)
      end

      private

      attr_reader :authority, :instance_id

      def authenticate_remote!
        audit["operation"] = "#{controller_name}.#{action_name}"
        if (reason = Hive::Remote::Protocol.interlock(mutation: !request.get? && !request.head?))
          audit["outcome"] = reason
          return render json: Hive::Remote::Protocol.unavailable, status: 503
        end
        query = Rack::Utils.parse_nested_query(request.query_string)
        bearer = request.headers["Authorization"].to_s.match(/\ABearer ([0-9a-f]{24}\.[0-9a-f]{64})\z/i)
        token = Hive::Remote::TokenStore.new.authenticate(bearer[1]) if bearer &&
          (query.keys & %w[token access_token authorization]).empty?
        return render_error(401, "invalid_token", "valid bearer authentication is required") unless token

        audit["token_id"] = token.fetch("id")
        @instance_id = Hive::RuntimeControlPlane.database.installation_identity.fetch(:installation_id)
        @authority = Hive::Remote::Authorization.new(token: token, installation_id: instance_id)
      end

      def authorized_project!(scope = nil)
        authority.scope!(scope) if scope
        project = authority.project!(params.fetch(:project))
        audit["project"] = project.fetch("name")
        project
      end

      def render_data(data, status: 200)
        audit["outcome"] = "ok_#{status}"
        render json: Hive::Remote::Protocol.envelope(instance_id: instance_id, data: data), status: status
      end

      def render_error(status, code, message, **details)
        audit["outcome"] = code
        render json: Hive::Remote::Protocol.error(code, message, instance_id: instance_id, **details), status: status
      end

      def audit
        request.env["hive.remote.audit"] ||= {
          "token_id" => "unknown", "project" => nil, "operation" => "api.request", "outcome" => "unavailable"
        }
      end
    end
  end
end
