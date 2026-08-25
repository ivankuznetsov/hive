require "test_helper"
require "hive/plan_review/workspace_scope"

class PlanReviewWorkspaceScopeTest < Minitest::Test
  include HiveTestHelper

  def test_codex_uses_its_native_workspace_write_sandbox
    scope = Hive::PlanReview::WorkspaceScope.launch_kwargs(
      profile: Hive::AgentProfiles.lookup(:codex), workspace: "/tmp/review", role: "primary"
    )

    assert_equal Hive::AgentProfile::WORKSPACE_WRITE_PERMISSION_MODE,
                 scope.fetch(:permission_mode)
    assert_nil scope.fetch(:allowed_tools)
    assert_nil scope.fetch(:disallowed_tools)
    refute scope.key?(:permission_arguments)
    refute_includes Hive::AgentProfiles.lookup(:codex).permission_flags(
      scope.fetch(:permission_mode)
    ), "--skip-git-repo-check"
  end

  # The disposable workspace is a complete checkout: read/search/shell can
  # inspect it, while edits remain scoped to that checkout and the
  # ArtifactFirewall retains custody of controller-owned task artifacts.
  def test_claude_can_reach_the_repo_while_edits_stay_in_the_workspace
    workspace = File.expand_path("/tmp/review")
    scope = Hive::PlanReview::WorkspaceScope.launch_kwargs(
      profile: Hive::AgentProfiles.lookup(:claude), workspace:, role: "planner_revision"
    )
    allowed = scope.fetch(:allowed_tools).join(" ")

    assert_equal Hive::PermissionScope::SCOPED_PERMISSION_MODE,
                 scope.fetch(:permission_mode)
    # Shell is required: the finding format needs SHA-256, and without it a
    # completed review cannot be emitted at all.
    assert_includes allowed, "Bash"
    refute_includes Array(scope.fetch(:disallowed_tools)), "Bash"
    assert_includes allowed, "Edit(//tmp/review/**)"
    refute_includes allowed, "bypassPermissions"
  end

  def test_pi_uses_the_native_review_runtime_without_managed_tool_confinement
    Dir.mktmpdir("hive-plan-review-pi") do |workspace|
      output_path = File.join(workspace, "hive-plan-review-result.json")
      scope = Hive::PlanReview::WorkspaceScope.launch_kwargs(
        profile: Hive::AgentProfiles.lookup(:pi), workspace:,
        output_path:, role: "primary"
      )

      assert_nil scope.fetch(:permission_mode)
      assert_nil scope.fetch(:allowed_tools)
      assert_nil scope.fetch(:disallowed_tools)
      refute scope.key?(:runtime_policy)
    end
  end

  def test_opencode_uses_a_typed_full_review_policy
    scope = Hive::PlanReview::WorkspaceScope.launch_kwargs(
      profile: Hive::AgentProfiles.lookup(:opencode),
      workspace: "/tmp/review", role: "primary"
    )

    assert_nil scope.fetch(:permission_mode)
    assert_nil scope.fetch(:allowed_tools)
    assert_nil scope.fetch(:disallowed_tools)
    policy = scope.fetch(:permission_policy)
    assert_instance_of Hive::AgentRuntime::OpenCodePermissionPolicy, policy
    assert_equal "allow", policy.rules.fetch("bash")
    assert_equal "allow", policy.rules.fetch("webfetch")
    assert_equal "allow", policy.rules.fetch("websearch")
    assert_equal "allow", policy.rules.dig("edit", "**")
    assert_equal "deny", policy.rules.dig("external_directory", "*")
    assert_equal "deny", policy.rules.fetch("task")
  end

  # The reviewer must be able to read the code, search it, shell out (the
  # finding format needs SHA-256), and fetch referenced docs.
  def test_reviewers_get_the_tools_review_actually_requires
    tools = Hive::PlanReview::WorkspaceScope::REVIEW_TOOLS

    %w[Read Grep Glob Bash WebFetch WebSearch].each do |tool|
      assert_includes tools, tool
    end
  end

  # grok confines the filesystem natively, the same way codex does, so it must
  # be admitted on capability rather than excluded by a hardcoded allowlist.
  def test_grok_is_admitted_through_native_sandbox_flags
    profile = Hive::AgentProfiles.lookup(:grok)

    assert profile.workspace_write_supported?,
           "grok declares --sandbox flags, so workspace write must be supported"
    kwargs = Hive::PlanReview::WorkspaceScope.launch_kwargs(
      profile:, workspace: "/tmp/review", role: "adversarial"
    )

    assert_equal Hive::AgentProfile::WORKSPACE_WRITE_PERMISSION_MODE,
                 kwargs.fetch(:permission_mode)
    refute kwargs.key?(:permission_arguments)
    assert_equal [ "--sandbox", "workspace", "--always-approve" ],
                 profile.permission_flags(kwargs.fetch(:permission_mode))
  end
end
