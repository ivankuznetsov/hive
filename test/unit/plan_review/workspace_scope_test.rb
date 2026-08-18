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

  def test_pi_reuses_managed_bubblewrap_with_one_host_output
    Dir.mktmpdir("hive-plan-review-pi") do |workspace|
      output_path = File.join(workspace, "hive-plan-review-result.json")
      policy = Struct.new(
        :permission_mode, :allowed_tools, :disallowed_tools,
        keyword_init: true
      ).new(
        permission_mode: nil,
        allowed_tools: [ "Read", "Edit(hive-plan-review-result.json)" ],
        disallowed_tools: []
      )
      observed = nil
      compiler = lambda do |spec, **kwargs|
        observed = [ spec, kwargs ]
        policy
      end

      scope = nil
      with_replaced_singleton_method(
        Hive::WorkflowPackage::RuntimePolicy, :compile_actor, compiler
      ) do
        scope = Hive::PlanReview::WorkspaceScope.launch_kwargs(
          profile: Hive::AgentProfiles.lookup(:pi), workspace:,
          output_path:, role: "primary"
        )
      end

      assert_same policy, scope.fetch(:runtime_policy)
      assert_equal [ "Read", "Edit(hive-plan-review-result.json)" ],
                   observed.first.fetch("tools")
      assert_equal workspace, observed.last.fetch(:task_folder)
      assert_equal workspace, observed.last.fetch(:package_root)
      assert_equal [ output_path ], observed.last.fetch(:managed_outputs)
    end
  end

  def test_pi_requires_an_output_inside_the_disposable_workspace
    Dir.mktmpdir("hive-plan-review-pi") do |workspace|
      profile = Hive::AgentProfiles.lookup(:pi)

      missing = assert_raises(Hive::ConfigError) do
        Hive::PlanReview::WorkspaceScope.launch_kwargs(
          profile:, workspace:, role: "primary"
        )
      end
      assert_includes missing.message, "exact output path"

      escaped = assert_raises(Hive::ConfigError) do
        Hive::PlanReview::WorkspaceScope.launch_kwargs(
          profile:, workspace:, output_path: File.join(File.dirname(workspace), "result.json"),
          role: "primary"
        )
      end
      assert_includes escaped.message, "inside the disposable workspace"
    end
  end

  # opencode declares no sandbox flags and has no bespoke confinement branch,
  # so it is the current example of a provider hive must refuse. grok used to
  # sit here; it now confines natively via `--sandbox workspace`.
  def test_provider_without_an_enforceable_scope_is_rejected
    error = assert_raises(Hive::ConfigError) do
      Hive::PlanReview::WorkspaceScope.launch_kwargs(
        profile: Hive::AgentProfiles.lookup(:opencode), workspace: "/tmp/review", role: "adversarial"
      )
    end

    assert_includes error.message, "cannot enforce disposable workspace confinement"
  end

  # grok confines the filesystem natively, the same way codex does, so it must
  # be admitted on capability rather than excluded by a hardcoded allowlist.
  def test_grok_is_admitted_through_native_sandbox_flags
    profile = Hive::AgentProfiles.lookup(:grok)

    assert profile.workspace_write_supported?,
           "grok declares --sandbox flags, so workspace write must be supported"
    assert Hive::PlanReview::WorkspaceScope.supported?(profile)

    kwargs = Hive::PlanReview::WorkspaceScope.launch_kwargs(
      profile:, workspace: "/tmp/review", role: "adversarial"
    )

    assert_equal Hive::AgentProfile::WORKSPACE_WRITE_PERMISSION_MODE,
                 kwargs.fetch(:permission_mode)
    assert_equal [ "--sandbox", "workspace", "--always-approve" ],
                 profile.permission_flags(kwargs.fetch(:permission_mode))
  end
end
