require "hive/agent_profile"
require "hive/agent_support"
require "hive/agent_runtime"
require "hive/config"
require "hive/permission_scope"

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
    # Reviewers now run from a disposable detached Git worktree. They get what
    # reviewing actually requires — repository context, search, shell and
    # network — without exposing the live checkout to their writes. The
    # ArtifactFirewall independently retains custody of controller-owned task
    # state and the required verdict output.
    module WorkspaceScope
      # What a reviewer needs to check a plan against the codebase it
      # describes, rather than against itself.
      REVIEW_TOOLS = %w[Read Grep Glob Bash WebFetch WebSearch].freeze

      module_function

      def launch_kwargs(profile:, workspace:, role:, output_path: nil)
        return workspace_write_kwargs(profile) if profile.workspace_write_supported?
        if (support = Hive::AgentSupport.for(profile))&.respond_to?(:plan_review_launch_kwargs)
          return support.plan_review_launch_kwargs(workspace:, role:, output_path:)
        end

        tools = REVIEW_TOOLS + write_tools(workspace)
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

      # Profiles that advertise workspace-write support confine writes to the
      # disposable Git worktree while leaving review capabilities intact.
      def workspace_write_kwargs(_profile)
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

      private_class_method :workspace_write_kwargs, :write_tools
    end
  end
end
