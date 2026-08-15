require "test_helper"
require "hive/plan_review/workspace_scope"

class PlanReviewWorkspaceScopeTest < Minitest::Test
  def test_codex_uses_its_native_workspace_write_sandbox
    scope = Hive::PlanReview::WorkspaceScope.launch_kwargs(
      profile: Hive::AgentProfiles.lookup(:codex), workspace: "/tmp/review", role: "primary"
    )

    assert_equal Hive::AgentProfile::WORKSPACE_WRITE_PERMISSION_MODE,
                 scope.fetch(:permission_mode)
    assert_nil scope.fetch(:allowed_tools)
    assert_nil scope.fetch(:disallowed_tools)
  end

  def test_claude_gets_absolute_read_and_edit_rules_for_only_the_disposable_workspace
    workspace = File.expand_path("/tmp/review")
    scope = Hive::PlanReview::WorkspaceScope.launch_kwargs(
      profile: Hive::AgentProfiles.lookup(:claude), workspace:, role: "planner_revision"
    )

    assert_equal Hive::PermissionScope::SCOPED_PERMISSION_MODE,
                 scope.fetch(:permission_mode)
    assert_equal [ "Read(//tmp/review/**)", "Edit(//tmp/review/**)" ],
                 scope.fetch(:allowed_tools)
    assert_includes scope.fetch(:disallowed_tools), "Bash"
    refute_includes scope.fetch(:allowed_tools).join(" "), "bypassPermissions"
  end

  def test_provider_without_an_enforceable_scope_is_rejected
    error = assert_raises(Hive::ConfigError) do
      Hive::PlanReview::WorkspaceScope.launch_kwargs(
        profile: Hive::AgentProfiles.lookup(:grok), workspace: "/tmp/review", role: "adversarial"
      )
    end

    assert_includes error.message, "cannot enforce disposable workspace confinement"
  end
end
