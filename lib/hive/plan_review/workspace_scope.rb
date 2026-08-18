require "hive/agent_profile"
require "hive/config"
require "hive/permission_scope"
require "hive/workflow_package/runtime_policy"

module Hive
  module PlanReview
    # Plan review used to run its reviewer inside a disposable temp directory
    # holding nothing but a copy of plan.md. That made the reviewer blind: it
    # could check the document against itself and nothing else — not grep the
    # code the plan describes, not read the wiki, not fetch a referenced doc,
    # and, having no shell, not even compute the SHA-256 the finding format
    # requires. A completed review could therefore fail to emit at all:
    #
    #   BLOCKER: the adversarial pass over plan.md completed, but no typed
    #   findings could be emitted because this execution environment has no
    #   way to compute SHA-256.
    #
    # Prevention bought little here. The reviewer's input is plan.md, written
    # by our own plan stage — not the untrusted task text that justifies
    # narrowing brainstorm/plan add-dirs against prompt injection. Meanwhile
    # the ArtifactFirewall already snapshots plan.md, meta.yml and every
    # plan-review record around the run, detecting and restoring tampering.
    # That is the same trust model execute, open_pr and artifacts run under.
    #
    # So reviewers now get what reviewing actually requires — the repository,
    # search, shell, network — while writes stay pointed at the disposable
    # workspace and the firewall remains the guard.
    module WorkspaceScope
      # What a reviewer needs to check a plan against the codebase it
      # describes, rather than against itself.
      REVIEW_TOOLS = %w[Read Grep Glob Bash WebFetch WebSearch].freeze

      module_function

      # Confinement no longer decides who may review, so no provider is
      # refused for lacking it. Whether a provider can be launched at all is
      # still the route resolver's capability probe to answer.
      def supported?(_profile) = true

      def launch_kwargs(profile:, workspace:, role:, output_path: nil)
        return workspace_write_kwargs if profile.workspace_write_supported?

        tools = REVIEW_TOOLS + write_tools(workspace)
        return pi_launch_kwargs(
          profile:, workspace:, role:, output_path:, tools:
        ) if profile.name == :pi

        scope = Hive::PermissionScope.resolve(
          { "preset" => "scoped", "tools" => tools },
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

      # codex and grok carry a real filesystem sandbox, which already confines
      # writes to the working directory while leaving reads, shell and network
      # intact. Nothing to add.
      def workspace_write_kwargs
        {
          permission_mode: Hive::AgentProfile::WORKSPACE_WRITE_PERMISSION_MODE,
          allowed_tools: nil,
          disallowed_tools: nil
        }
      end

      # Edit(path) alone: Claude does not enforce Write(path), so granting it
      # would be a rule that reads like a restriction and enforces nothing.
      def write_tools(workspace)
        [ "Edit(#{File.expand_path(workspace.to_s)}/**)" ]
      end

      def pi_launch_kwargs(profile:, workspace:, role:, output_path:, tools:)
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
          { "preset" => "scoped", "tools" => tools },
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
      private_class_method :pi_launch_kwargs, :workspace_write_kwargs, :write_tools
    end
  end
end
