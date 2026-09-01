require "json"
require "hive/config"
require "hive/paths"
require "hive/runtime_control_plane/cutover"
require "hive/schemas"

module Hive
  module Commands
    # Read-only diagnosis or explicit forward convergence. There is no restore
    # or downgrade surface after the irreversible legacy seal.
    class Runtime
      ACTIONS = %w[status resume].freeze

      def initialize(action, json: false, output: $stdout,
                     state_home: Hive::Paths.state_home,
                     projects: Hive::Config.registered_projects)
        @action = action.to_s
        @json = json
        @output = output
        @state_home = File.expand_path(state_home)
        @projects = projects
      end

      def call
        unless ACTIONS.include?(@action)
          raise Hive::UsageError, "hive runtime: expected #{ACTIONS.join(' or ')}"
        end
        result = @action == "status" ? status : resume_cutover
        envelope = {
          "schema" => "hive-runtime-maintenance",
          "schema_version" => Hive::Schemas::SCHEMA_VERSIONS.fetch("hive-runtime-maintenance"),
          "action" => @action, "ok" => true, "result" => wire(result)
        }
        @json ? @output.puts(JSON.generate(envelope)) : render(envelope.fetch("result"))
        0
      rescue Hive::Error => error
        emit_json_error(error) if @json
        raise
      end

      private

      def status
        database = Hive::RuntimeControlPlane::Database.new(
          path: Hive::Paths.runtime_control_plane_path(@state_home)
        )
        Hive::RuntimeControlPlane::Cutover.inspect_status(
          state_home: @state_home,
          database: database
        )
      ensure
        database&.disconnect
      end

      def resume_cutover
        Hive::RuntimeControlPlane::Cutover.resume(state_home: @state_home, projects: @projects)
      end

      def wire(result)
        RuntimeControlPlane::Codec.normalize(result.respond_to?(:to_h) ? result.to_h : result)
      end

      def emit_json_error(error)
        next_action = error.respond_to?(:action) && error.action
        if !error.is_a?(Hive::UsageError) && next_action.to_s.empty?
          next_action = @action == "status" ?
            "repair the reported runtime evidence, then run hive runtime status" :
            "run hive runtime status and follow its forward-only recovery action"
        end
        @output.puts(JSON.generate(Hive::Schemas::ErrorEnvelope.build(
          schema: "hive-runtime-maintenance", error: error,
          error_kind: error.is_a?(Hive::UsageError) ? "usage" : "runtime",
          extras: {
            "action" => @action,
            "runtime_code" => error.respond_to?(:code) ? error.code.to_s : "usage",
            "next_action" => next_action,
            "details" => error.respond_to?(:details) ? RuntimeControlPlane::Codec.normalize(error.details) : {}
          }
        )))
      end

      def render(result)
        result.each { |key, value| @output.puts "#{key}: #{value.is_a?(Hash) ? JSON.generate(value) : value}" }
      end
    end
  end
end
