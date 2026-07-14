require "hive/permission_scope"

module Hive
  module Honeycomb
    module PermissionSummary
      module_function

      def build(workflow)
        contexts = workflow.stages.flat_map { |stage| stage_contexts(stage) }
                           .sort_by { |row| row.fetch("context") }
                           .freeze
        {
          "contexts" => contexts,
          "aggregate" => {
            "presets" => contexts.map { |row| row.fetch("preset") }.uniq.sort.freeze,
            "tools" => contexts.flat_map { |row| row.fetch("tools") }.uniq.sort.freeze,
            "dirs" => contexts.flat_map { |row| row.fetch("dirs") }.uniq.sort.freeze,
            "shell_exposures" => contexts.map { |row| row.fetch("shell_exposure") }.uniq.sort.freeze
          }.freeze
        }.freeze
      end

      def stage_contexts(stage)
        rows = [ context_row(
          context: "stage:#{stage.name}",
          kind: stage.kind.to_s,
          permissions: stage.permissions,
          executable: stage.kind == :agent
        ) ]
        return rows unless stage.kind == :council

        Array(stage.reviewers).each do |reviewer|
          rows << context_row(
            context: "stage:#{stage.name}/reviewer:#{reviewer.name}",
            kind: reviewer.command ? "command" : "reviewer",
            permissions: reviewer.permissions,
            executable: true,
            command: !reviewer.command.nil?
          )
        end
        if stage.council&.revise
          revise = stage.council.revise
          rows << context_row(
            context: "stage:#{stage.name}/revise",
            kind: revise.command ? "command" : "revise",
            permissions: revise.permissions,
            executable: true,
            command: !revise.command.nil?
          )
        end
        rows
      end

      def context_row(context:, kind:, permissions:, executable:, command: false)
        unless executable
          return {
            "context" => context,
            "kind" => kind,
            "preset" => "not_applicable",
            "tools" => [].freeze,
            "dirs" => [].freeze,
            "shell_exposure" => permissions.nil? ? "none" : declaration(permissions).fetch("shell_exposure"),
            "shell_justification" => justification(permissions)
          }.freeze
        end

        data = declaration(permissions)
        # Intentional fail-closed asymmetry: a command-owned context has its
        # shell_exposure forced to "command" (never "explicit_bash") while any
        # declared shell_justification is retained, so a deny hit owned by a
        # command context always blocks even when justified. This is the safe
        # direction; it is effectively unreachable today because command
        # reviewers own no instruction file that could carry a deny match.
        # Computed into a local rather than mutating the declaration hash so
        # this stays correct if `declaration` is ever memoized or frozen.
        shell_exposure = command ? "command" : data.fetch("shell_exposure")
        {
          "context" => context,
          "kind" => kind,
          "preset" => data.fetch("preset"),
          "tools" => data.fetch("tools"),
          "dirs" => data.fetch("dirs"),
          "shell_exposure" => shell_exposure,
          "shell_justification" => data["shell_justification"]
        }.freeze
      end

      def declaration(permissions)
        return {
          "preset" => "inherit", "tools" => [].freeze, "dirs" => [].freeze,
          "shell_exposure" => "inherit", "shell_justification" => nil
        } if permissions.nil?

        spec = permissions.is_a?(Hash) ? stringify_keys(permissions) : { "preset" => permissions.to_s }
        preset = spec.fetch("preset")
        tools = Array(spec["tools"]).map(&:to_s).freeze
        dirs = Array(spec["dirs"]).map(&:to_s).freeze
        shell = case preset
        when Hive::PermissionScope::YOLO then "unrestricted"
        when "read-only" then "disabled"
        when "scoped"
          # Reuse the one shell-grant predicate PermissionScope resolves against
          # so this summary can never desync from the scope that actually runs.
          Hive::PermissionScope.grants_bash?(spec) ? "explicit_bash" : "disabled"
        else "unknown"
        end
        {
          "preset" => preset,
          "tools" => tools,
          "dirs" => dirs,
          "shell_exposure" => shell,
          "shell_justification" => spec["shell_justification"]
        }
      end

      def justification(permissions)
        permissions.is_a?(Hash) ? (permissions["shell_justification"] || permissions[:shell_justification]) : nil
      end

      def stringify_keys(hash)
        hash.to_h { |key, value| [ key.to_s, value ] }
      end
    end
  end
end
