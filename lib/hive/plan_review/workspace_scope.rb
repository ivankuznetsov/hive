require "hive/agent_profile"
require "hive/config"
require "hive/permission_scope"
require "hive/workflow_package/runtime_policy"

module Hive
  module PlanReview
    module WorkspaceScope
      module_function

      def supported?(profile)
        profile.workspace_write_supported? || %i[claude pi].include?(profile.name)
      end

      def launch_kwargs(profile:, workspace:, role:, output_path: nil)
        unless supported?(profile)
          raise Hive::ConfigError,
                "plan review #{role} provider #{profile.name.inspect} cannot enforce disposable workspace confinement"
        end

        return pi_launch_kwargs(
          profile:, workspace:, role:, output_path:
        ) if profile.name == :pi

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

      def pi_launch_kwargs(profile:, workspace:, role:, output_path:)
        if output_path.to_s.empty?
          raise Hive::ConfigError,
                "plan review #{role} Pi confinement requires an exact output path"
        end

        relative = File.expand_path(output_path).delete_prefix("#{File.expand_path(workspace)}/")
        if relative == File.expand_path(output_path) || relative.empty?
          raise Hive::ConfigError,
                "plan review #{role} Pi output must stay inside the disposable workspace"
        end

        runtime_policy = Hive::WorkflowPackage::RuntimePolicy.compile_actor(
          {
            "preset" => "scoped",
            "tools" => [ "Read", "Edit(#{relative})" ]
          },
          task_folder: workspace,
          package_root: workspace,
          profile:,
          managed_outputs: [ output_path ]
        )
        {
          permission_mode: runtime_policy.permission_mode,
          allowed_tools: runtime_policy.allowed_tools,
          disallowed_tools: runtime_policy.disallowed_tools,
          runtime_policy:
        }
      end
      private_class_method :pi_launch_kwargs
    end
  end
end
