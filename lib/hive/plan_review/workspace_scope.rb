require "hive/agent_profile"
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

        # Pi's managed-workflow wrapper is deliberately read-only and cannot
        # expose Bash or network access. Those are both required here: the
        # reviewer must inspect the repository and referenced documentation,
        # and its finding format requires SHA-256. Plan review uses the same
        # ArtifactFirewall detection-and-restore boundary as the other native
        # stages, so launch Pi directly instead of pretending its managed
        # output wrapper can enforce this broader review contract.
        return unrestricted_kwargs if profile.name == :pi

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

      def unrestricted_kwargs
        {
          permission_mode: nil,
          allowed_tools: nil,
          disallowed_tools: nil
        }
      end

      # Edit(path) alone: Claude does not enforce Write(path), so granting it
      # would be a rule that reads like a restriction and enforces nothing.
      def write_tools(workspace)
        [ "Edit(#{File.expand_path(workspace.to_s)}/**)" ]
      end

      private_class_method :unrestricted_kwargs, :workspace_write_kwargs, :write_tools
    end
  end
end
