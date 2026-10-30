require "json"
require "hive/config"
require "hive/paths"
require "hive/runtime_control_plane/installation"
require "hive/schemas"
require "hive/worktree"

module Hive
  module Commands
    # Read-only diagnosis of the current runtime database, plus read-only
    # listings of registered projects and runtime payload references for
    # external audits (e.g. a container's read-only workspace audit).
    class Runtime
      ACTIONS = %w[status projects payloads].freeze

      def initialize(action, json: false, output: $stdout,
                     state_home: Hive::Paths.state_home)
        @action = action.to_s
        @json = json
        @output = output
        @state_home = File.expand_path(state_home)
      end

      def call
        unless ACTIONS.include?(@action)
          raise Hive::UsageError, "hive runtime: expected one of #{ACTIONS.join(', ')}"
        end
        result = case @action
        when "status" then Hive::RuntimeControlPlane::Installation.status(state_home: @state_home)
        when "projects" then projects
        else Hive::RuntimeControlPlane::Installation.payloads(state_home: @state_home)
        end
        healthy = @action != "status" || result.fetch("phase") == "active"
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

      # Registry rows plus each project's effective worktree root. Project
      # config is not loaded (no validation, workflow loading, or managed-store
      # reconciliation); only its raw `worktree_root` is read, so a broken
      # project cannot hide the paths an auditor needs to check.
      def projects
        {
          "registry_path" => Hive::Config.global_config_path,
          "projects" => Hive::Config.registered_projects.map do |project|
            project.slice("name", "project_id", "path", "real_path", "hive_state_path")
                   .merge(worktree_root(project.fetch("path")))
          end
        }
      end

      # Resolved through Worktree.canonical_root, the resolver Hive's worktree
      # commands use (a relative value expands against the current directory,
      # exactly as there). Per-project failures are reported, not raised.
      def worktree_root(project_root)
        config_path, data = Hive::Config.read_project_config(project_root)
        raise Hive::ConfigError, "config.yml at #{config_path} is missing" unless File.file?(config_path)

        value = data["worktree_root"]
        raise Hive::ConfigError, "worktree_root in #{config_path} must be a string" unless value.nil? || value.is_a?(String)

        { "worktree_root" => Hive::Worktree.canonical_root(project_root, config: data) }
      rescue Hive::ConfigError, ArgumentError => error
        { "worktree_root" => nil, "worktree_root_error" => error.message }
      end

      def wire(result)
        RuntimeControlPlane::Codec.normalize(result.respond_to?(:to_h) ? result.to_h : result)
      end

      def emit_json_error(error)
        next_action = error.respond_to?(:action) ? error.action : nil
        if !error.is_a?(Hive::UsageError) && next_action.to_s.empty?
          target = @action == "projects" ? "global Hive registry" : "reported runtime database"
          next_action = "repair the #{target}, then run hive runtime #{@action}"
        end
        @output.puts(JSON.generate(Hive::Schemas::ErrorEnvelope.build(
          schema: "hive-runtime-maintenance", error: error,
          error_kind: error.is_a?(Hive::UsageError) ? "usage" : "runtime",
          extras: {
            "action" => @action,
            "runtime_code" => runtime_code(error),
            "next_action" => next_action,
            "details" => error.respond_to?(:details) ? RuntimeControlPlane::Codec.normalize(error.details) : {}
          }
        )))
      end

      def runtime_code(error)
        return error.code.to_s if error.respond_to?(:code)

        error.is_a?(Hive::ConfigError) ? "config" : "usage"
      end

      def render(result)
        result.each do |key, value|
          @output.puts "#{key}: #{value.is_a?(Hash) || value.is_a?(Array) ? JSON.generate(value) : value}"
        end
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
