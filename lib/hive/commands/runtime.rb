require "json"
require "hive/paths"
require "hive/runtime_control_plane/installation"
require "hive/schemas"

module Hive
  module Commands
    # Read-only diagnosis of the current runtime database.
    class Runtime
      ACTIONS = %w[status].freeze

      def initialize(action, json: false, output: $stdout,
                     state_home: Hive::Paths.state_home)
        @action = action.to_s
        @json = json
        @output = output
        @state_home = File.expand_path(state_home)
      end

      def call
        unless ACTIONS.include?(@action)
          raise Hive::UsageError, "hive runtime: expected #{ACTIONS.join(' or ')}"
        end
        result = Hive::RuntimeControlPlane::Installation.status(state_home: @state_home)
        healthy = result.fetch("phase") == "active"
        envelope = {
          "schema" => "hive-runtime-maintenance",
          "schema_version" => Hive::Schemas::SCHEMA_VERSIONS.fetch("hive-runtime-maintenance"),
          "action" => @action, "ok" => healthy, "result" => wire(result)
        }
        @json ? @output.puts(JSON.generate(envelope)) : render(envelope.fetch("result"))
        healthy ? 0 : 1
      rescue Hive::Error => error
        emit_json_error(error) if @json
        raise
      end

      private

      def wire(result)
        RuntimeControlPlane::Codec.normalize(result.respond_to?(:to_h) ? result.to_h : result)
      end

      def emit_json_error(error)
        next_action = error.respond_to?(:action) ? error.action : nil
        if !error.is_a?(Hive::UsageError) && next_action.to_s.empty?
          next_action = "repair the reported runtime database, then run hive runtime status"
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

# The pre-dispatch JSON usage contract for this command boundary preserves the
# runtime action argv named (see Hive::CliUsageContracts).
require "hive/cli_usage_contracts"

Hive::CliUsageContracts.declare("runtime") do |argv, command_index:, option_argv:|
  action = Hive::CliUsageContracts.positionals(argv, command_index).first || "status"
  {
    schema: "hive-runtime-maintenance", error_kind: "usage",
    extras: {
      "action" => action, "runtime_code" => "usage",
      "next_action" => nil, "details" => {}
    }
  }
end
