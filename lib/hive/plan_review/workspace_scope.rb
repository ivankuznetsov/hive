require "hive/agent_profile"
require "hive/config"
require "hive/permission_scope"

module Hive
  module PlanReview
    module WorkspaceScope
      module_function

      def supported?(profile)
        profile.workspace_write_supported? || profile.name == :claude
      end

      def launch_kwargs(profile:, workspace:, role:)
        unless supported?(profile)
          raise Hive::ConfigError,
                "plan review #{role} provider #{profile.name.inspect} cannot enforce disposable workspace confinement"
        end

        if profile.workspace_write_supported?
          return {
            permission_mode: Hive::AgentProfile::WORKSPACE_WRITE_PERMISSION_MODE,
            allowed_tools: nil,
            disallowed_tools: nil
          }
        end

        scope = Hive::PermissionScope.resolve(
          {
            "preset" => "scoped",
            "tools" => %w[Read(./**) Edit(./**)]
          },
          task_folder: workspace,
          profile:,
          stage: "plan_review.#{role}"
        )
        {
          permission_mode: scope.permission_mode,
          allowed_tools: scope.allowed_tools,
          disallowed_tools: scope.disallowed_tools
        }
      end
    end
  end
end
