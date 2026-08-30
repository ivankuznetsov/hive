require "json"
require "hive/config"
require "hive/paths"
require "hive/runtime_control_plane/cutover"

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
        envelope = { "schema" => "hive-runtime-maintenance", "action" => @action,
                     "ok" => true, "result" => wire(result) }
        @json ? @output.puts(JSON.generate(envelope)) : render(envelope.fetch("result"))
        0
      end

      private

      def status
        Hive::RuntimeControlPlane::Cutover.inspect_status(
          state_home: @state_home,
          database: Hive::RuntimeControlPlane::Database.new(
            path: Hive::Paths.runtime_control_plane_path(@state_home)
          )
        )
      end

      def resume_cutover
        Hive::RuntimeControlPlane::Cutover.resume(state_home: @state_home, projects: @projects)
      end

      def wire(result)
        result.respond_to?(:to_h) ? result.to_h.transform_keys(&:to_s) : result
      end

      def render(result)
        result.each { |key, value| @output.puts "#{key}: #{value.is_a?(Hash) ? JSON.generate(value) : value}" }
      end
    end
  end
end
