# frozen_string_literal: true

require "hive/remote/token_store"
require "hive/remote/protocol"
require "hive/remote/read_service"
require "hive/remote/serializers"
require "hive/remote/question_handles"
require "hive/remote/command_service"

module Api
  module V1
    class BaseController < ActionController::API
      before_action :authenticate_remote!

      rescue_from StandardError do
        render_error(503, "unavailable", "remote API is unavailable")
      end
      rescue_from Hive::Error do |error|
        status, code = case error
        when Hive::CommandConflict then [ 409, "conflict" ]
        when Hive::CommandInProgress then [ 409, "in_progress" ]
        when Hive::CommandUnresolved then [ 409, "unresolved" ]
        when Hive::StaleOperationalObservation, Hive::WrongStage then [ 409, "stale" ]
        when Hive::InvalidTaskPath then [ 404, "not_found" ]
        when Hive::ConfigError, Hive::ConcurrentRunError, Hive::CommandCapacityError then [ 503, "unavailable" ]
        when Hive::Commands::Answer::InvalidAnswer then [ 422, "validation" ]
        when Hive::UsageError then [ 400, "malformed_input" ]
        else [ 422, "validation" ]
        end
        render_error(status, code, code == "not_found" ? "resource not found" : "remote operation could not be completed")
      end
      rescue_from ActionController::ParameterMissing, ActionDispatch::Http::Parameters::ParseError do
        render_error(400, "malformed_input", "invalid request")
      end
      rescue_from Hive::OperationalActionUsageError do |error|
        # These native errors are also used by local tools. Only recognized
        # local-only transitions receive guidance; never forward their text.
        local = [
          "this recovery must be performed locally",
          "this recovery requires force; retry locally",
          "this transition requires force; advance locally",
          "this transition requires a terminal marker; advance locally"
        ].include?(error.message)
        render_error(422, "validation", local ? "advance this task locally" : "remote operation could not be completed")
      end
      rescue_from Hive::Remote::Error do |error|
        render_error(error.status, error.code, error.message)
      end

      private

      attr_reader :authority, :instance_id

      def authenticate_remote!
        audit["operation"] = "#{controller_name}.#{action_name}"
        if (reason = Hive::Remote::Protocol.interlock(mutation: !Hive::Remote::Contract::SAFE_METHODS.include?(request.request_method)))
          audit["outcome"] = reason
          return render json: Hive::Remote::Protocol.unavailable, status: 503
        end
        query = Rack::Utils.parse_nested_query(request.query_string)
        bearer = request.headers["Authorization"].to_s.match(/\ABearer ([0-9a-f]{24}\.[0-9a-f]{64})\z/i)
        token = Hive::Remote::TokenStore.new.authenticate(bearer[1]) if bearer &&
          (query.keys & %w[token access_token authorization]).empty?
        return render_error(401, "invalid_token", "valid bearer authentication is required") unless token

        audit["token_id"] = token.fetch("id")
        @instance_id = Hive::RuntimeControlPlane.database.cached_installation_identity.fetch(:installation_id)
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
        render body: JSON.generate(Hive::Remote::Protocol.envelope(instance_id: instance_id, data: data)),
          content_type: "application/json", status: status
      end

      def render_error(status, code, message, **details)
        audit["outcome"] = code
        response.set_header("WWW-Authenticate", "Bearer") if status == 401
        render json: Hive::Remote::Protocol.error(code, message, instance_id: instance_id, **details), status: status
      end

      def read_service
        @read_service ||= Hive::Remote::ReadService.new
      end

      def handles
        @handles ||= Hive::Remote::QuestionHandles.new
      end

      def serializers
        @serializers ||= Hive::Remote::Serializers.new(project_names: authority.projects.map { |project| project.fetch("name") })
      end

      def read_target!(validate_state: true)
        resolve_target!("read", validate_state: validate_state)
      end

      def resolve_target!(scope = nil, validate_state: true)
        project = authorized_project!(scope)
        identifier = params.fetch(:task).to_s
        unless identifier.match?(Hive::Remote::Contract::TASK_ID)
          raise Hive::InvalidTaskPath, "unknown task"
        end
        task = Hive::TaskResolver.new(identifier, project_filter: project.fetch("name")).resolve
        Hive::Remote::ReadService.validate_state!(task) if validate_state
        [ project, task ]
      end

      def response_limit(maximum)
        value = params[:max_bytes]
        return maximum if value.nil?
        limit = Integer(value.to_s, 10)
        raise ArgumentError unless limit.positive?
        [ limit, maximum ].min
      rescue ArgumentError, TypeError
        raise Hive::UsageError, "max_bytes must be a positive integer"
      end

      def render_bounded(data, maximum: Hive::Remote::Protocol::MAX_RESPONSE_BYTES, limit: nil)
        Hive::Remote::Serializers.bound!(data, max_bytes: limit || response_limit(maximum), instance_id: instance_id)
        render_data(data)
      end

      def audit
        request.env["hive.remote.audit"] ||= {
          "token_id" => "unknown", "project" => nil, "operation" => "api.request", "outcome" => "unavailable"
        }
      end
    end
  end
end
