require "test_helper"
require "json"
require "shellwords"
require "time"
require "hive/claude_launcher"
require "hive/stages/base"
require "hive/task"

class ClaudeLauncherTest < Minitest::Test
  include HiveTestHelper

  def test_headless_mode_delegates_to_base_spawn_agent
    with_tmp_task do |task|
      captured = nil
      original = Hive::Stages::Base.singleton_class.instance_method(:spawn_agent)
      capture_unbound_method_on(Hive::Stages::Base, :spawn_agent, original) do
        Hive::Stages::Base.define_singleton_method(:spawn_agent) do |spawn_task, **kwargs|
          captured = [ spawn_task, kwargs ]
          { status: :complete }
        end

        result = Hive::ClaudeLauncher.launch!(
          task: task,
          cfg: { "claude" => { "permission_mode" => "auto" } },
          prompt: "prompt",
          add_dirs: [ task.folder ],
          cwd: task.folder,
          max_budget_usd: 1,
          timeout_sec: 1,
          log_label: "test",
          status_mode: :state_file_marker,
          allowed_tools: %w[Read LS],
          disallowed_tools: %w[Write Bash],
          resource_guards: [ { "field" => "timeout_sec", "value" => 1 } ]
        )

        assert_equal({ status: :complete }, result)
        assert_equal task, captured.fetch(0)
        assert_equal "prompt", captured.fetch(1).fetch(:prompt)
        assert_equal :claude, captured.fetch(1).fetch(:profile).name
        assert_equal "auto", captured.fetch(1).fetch(:permission_mode)
        assert_equal %w[Read LS], captured.fetch(1).fetch(:allowed_tools)
        assert_equal %w[Write Bash], captured.fetch(1).fetch(:disallowed_tools)
        assert_equal [ { "field" => "timeout_sec", "value" => 1 } ],
                     captured.fetch(1).fetch(:resource_guards)
      end
    end
  end

  # A config that still carries the retired `claude.mode: tmux` key launches
  # through the headless spawn path like every other Claude launch.
  def test_legacy_tmux_mode_config_still_launches_headless
    with_tmp_task do |task|
      captured = nil
      spawn = lambda do |_task, **kwargs|
        captured = kwargs
        { status: :complete }
      end

      with_replaced_singleton_method(Hive::Stages::Base, :spawn_agent, spawn) do
        result = Hive::ClaudeLauncher.launch!(
          task: task,
          cfg: { "claude" => { "mode" => "tmux", "permission_mode" => "auto" } },
          prompt: "prompt",
          add_dirs: [ task.folder ],
          cwd: task.folder,
          max_budget_usd: 1,
          timeout_sec: 1,
          log_label: "test",
          status_mode: :state_file_marker
        )

        assert_equal({ status: :complete }, result)
        assert_equal :claude, captured.fetch(:profile).name
        assert_equal "auto", captured.fetch(:permission_mode)
      end
    end
  end

  def test_headless_mode_assembles_mcp_config_and_allowed_tools_flags
    with_tmp_task do |task|
      captured = nil
      original = Hive::Stages::Base.singleton_class.instance_method(:spawn_agent)
      capture_unbound_method_on(Hive::Stages::Base, :spawn_agent, original) do
        Hive::Stages::Base.define_singleton_method(:spawn_agent) do |_spawn_task, **kwargs|
          captured = kwargs
          { status: :complete }
        end

        Hive::ClaudeLauncher.launch!(
          task: task,
          cfg: { "claude" => { "permission_mode" => "auto" } },
          prompt: "prompt",
          add_dirs: [ task.folder ],
          cwd: task.folder,
          max_budget_usd: 1,
          timeout_sec: 1,
          log_label: "test",
          status_mode: :state_file_marker,
          allowed_tools: "Read,mcp__screenote__list_projects",
          mcp_config_path: "/tmp/screenote.mcp.json",
          strict_mcp_config: true
        )

        # The headless branch passes allowed_tools through as a kwarg (Agent
        # renders it to --allowedTools downstream, alongside disallowed_tools)
        # and appends mcp_cli_flags after any cfg-derived flags. Assert both
        # halves of that assembly: the tool kwarg and the trailing mcp flags.
        assert_equal "Read,mcp__screenote__list_projects", captured.fetch(:allowed_tools)
        assert_equal(
          %w[--mcp-config /tmp/screenote.mcp.json --strict-mcp-config],
          captured.fetch(:cli_flags).last(3)
        )
      end
    end
  end

  # The headless branch delegates to Stages::Base.spawn_agent, which owns
  # the AskUserQuestion deny: a plan launch with no caller deny must still
  # render it, and per-stage model/effort must reach argv unchanged.
  def test_headless_plan_launch_denies_ask_user_question_and_keeps_model_effort
    with_tmp_task(stage: "3-plan") do |task|
      prepare_test_task_run(task.folder)
      File.write(task.state_file, "<!-- WAITING -->\n")
      log_dir = File.join(File.dirname(task.folder), "argv-log")
      FileUtils.mkdir_p(log_dir)
      fake_bin = File.expand_path("../fixtures/fake-claude", __dir__)
      with_env("HIVE_CLAUDE_BIN" => fake_bin, "HIVE_FAKE_CLAUDE_LOG_DIR" => log_dir) do
        Hive::AgentProfile.reset_version_cache!
        Hive::ClaudeLauncher.launch!(
          task: task,
          cfg: {},
          prompt: "plan",
          add_dirs: [ task.folder ],
          cwd: task.folder,
          max_budget_usd: 1,
          timeout_sec: 5,
          log_label: "plan",
          allowed_tools: %w[Read Write Edit LS],
          model: "opus",
          effort: "high"
        )
      end

      argv = File.readlines(File.join(log_dir, "fake-claude-argv.log"), chomp: true)
      deny_index = argv.index("arg=--disallowedTools")
      refute_nil deny_index, "headless Claude launch must pass --disallowedTools"
      assert_equal "arg=AskUserQuestion", argv.fetch(deny_index + 1)
      assert_equal "arg=opus", argv.fetch(argv.index("arg=--model") + 1)
      assert_equal "arg=high", argv.fetch(argv.index("arg=--effort") + 1)
    ensure
      Hive::AgentProfile.reset_version_cache!
    end
  end

  def test_launcher_rejects_non_claude_profile
    with_tmp_task do |task|
      err = assert_raises(Hive::AgentError) do
        Hive::ClaudeLauncher.launch!(
          task: task,
          cfg: {},
          prompt: "prompt",
          add_dirs: [],
          cwd: task.folder,
          max_budget_usd: 1,
          timeout_sec: 1,
          log_label: "test",
          profile: Hive::AgentProfiles.lookup(:codex)
        )
      end

      assert_match(/only supports the claude profile/, err.message)
    end
  end

  def test_launch_passes_per_stage_model_and_effort_over_project_pins
    with_tmp_task do |task|
      cfg = { "claude" => { "model" => "sonnet", "effort" => "medium" } }
      captured_flags = nil
      spawn = lambda do |_task, **kwargs|
        captured_flags = kwargs[:cli_flags]
        { status: :complete }
      end
      with_replaced_singleton_method(Hive::Stages::Base, :spawn_agent, spawn) do
        Hive::ClaudeLauncher.launch!(
          task: task, cfg: cfg, prompt: "prompt", add_dirs: [], cwd: task.folder,
          max_budget_usd: 1, timeout_sec: 5, log_label: "brainstorm",
          model: "claude-opus-5-5", effort: "high"
        )
      end

      assert_equal %w[--model claude-opus-5-5 --effort high], captured_flags
    end
  end

  # Stages splat `model_launch_arguments` into spawn_claude!, so every key it
  # can return must be an accepted keyword (a missing one raised
  # "unknown keywords: :model, :effort" from brainstorm).
  def test_spawn_claude_accepts_every_model_launch_argument
    accepted = Hive::Stages::Base.method(:spawn_claude!).parameters
                                 .select { |kind, _| %i[key keyreq].include?(kind) }.map(&:last)
    launch_accepted = Hive::ClaudeLauncher.method(:launch!).parameters
                                          .select { |kind, _| %i[key keyreq].include?(kind) }.map(&:last)

    %i[model effort routing_arguments].each do |key|
      assert_includes accepted, key
      assert_includes launch_accepted, key
    end
  end

  def test_spawn_claude_bang_propagates_agent_error_unchanged
    # `spawn_claude!` does not catch launcher AgentErrors; the 6-review
    # stage relies on that propagation so it never writes a marker onto a
    # synthetic task's state_file. Per-stage callers that want the marker
    # use `spawn_claude_with_failure_marker!` (see below).
    with_tmp_task do |task|
      original = Hive::ClaudeLauncher.method(:launch!)
      capture_unbound_method(:launch!, original) do
        Hive::ClaudeLauncher.define_singleton_method(:launch!) do |**_kwargs|
          raise Hive::AgentError, "claude exited before start"
        end

        assert_raises(Hive::AgentError) do
          Hive::Stages::Base.spawn_claude!(
            task,
            {},
            prompt: "prompt",
            add_dirs: [ task.folder ],
            cwd: task.folder,
            max_budget_usd: 1,
            timeout_sec: 1,
            log_label: "test",
            status_mode: :state_file_marker
          )
        end
      end
    end
  end

  def test_spawn_claude_with_failure_marker_records_claude_launch_failed
    with_tmp_task do |task|
      original = Hive::ClaudeLauncher.method(:launch!)
      capture_unbound_method(:launch!, original) do
        Hive::ClaudeLauncher.define_singleton_method(:launch!) do |**_kwargs|
          raise Hive::AgentError, "claude exited before start"
        end

        result = nil
        _out, err = capture_io do
          result = Hive::Stages::Base.spawn_claude_with_failure_marker!(
            task,
            {},
            prompt: "prompt",
            add_dirs: [ task.folder ],
            cwd: task.folder,
            max_budget_usd: 1,
            timeout_sec: 1,
            log_label: "test",
            status_mode: :state_file_marker
          )
        end

        marker = Hive::Markers.current(task.state_file)
        assert_equal({ status: :error, error_message: "claude exited before start" }, result)
        assert_equal :error, marker.name
        assert_equal "claude_launch_failed", marker.attrs["reason"]
        assert_equal "Hive::AgentError", marker.attrs["exception_class"]
        assert_match(/claude exited before start/, marker.attrs["message"])
        assert_match(/claude launch failed: claude exited before start/, err)
      end
    end
  end

  def test_spawn_claude_with_failure_marker_reraises_provider_route_failures
    with_tmp_task do |task|
      original = Hive::ClaudeLauncher.method(:launch!)
      capture_unbound_method(:launch!, original) do
        Hive::ClaudeLauncher.define_singleton_method(:launch!) do |**_kwargs|
          raise Hive::ProviderRouteFailed, "route failed"
        end

        assert_raises(Hive::ProviderRouteFailed) do
          Hive::Stages::Base.spawn_claude_with_failure_marker!(
            task, {}, prompt: "prompt", max_budget_usd: 1, timeout_sec: 1
          )
        end
      end
    end
  end

  # ── KTD10: tmux-era scratch settings are repaired before a launch ──────

  def test_launch_restores_backed_up_project_settings_in_task_folder_and_cwd
    with_tmp_task do |task|
      worktree = File.join(File.dirname(task.folder), "worktree")
      [ task.folder, worktree ].each do |dir|
        settings = write_settings(dir, legacy_stop_hook_stub(task.folder))
        File.write("#{settings}.hive-pre-install", %({"enabledPlugins":{"frontend-design@official":true}}))
        File.chmod(0o444, settings)
      end

      launch_with_stubbed_spawn(task, cwd: worktree)

      [ task.folder, worktree ].each do |dir|
        settings = File.join(dir, ".claude", "settings.json")
        assert_equal %({"enabledPlugins":{"frontend-design@official":true}}), File.read(settings)
        refute File.exist?("#{settings}.hive-pre-install"), "backup must be consumed in #{dir}"
      end
    end
  end

  def test_launch_removes_a_stop_hook_stub_without_backup
    with_tmp_task do |task|
      worktree = File.join(File.dirname(task.folder), "worktree")
      [ task.folder, worktree ].each do |dir|
        File.chmod(0o444, write_settings(dir, legacy_stop_hook_stub(dir)))
      end

      launch_with_stubbed_spawn(task, cwd: worktree)

      [ task.folder, worktree ].each do |dir|
        refute File.exist?(File.join(dir, ".claude", "settings.json")), "stub must be removed in #{dir}"
        refute Dir.exist?(File.join(dir, ".claude")), "emptied .claude dir must be removed in #{dir}"
      end
    end
  end

  def test_launch_keeps_the_claude_dir_when_a_stub_has_neighbours
    with_tmp_task do |task|
      settings = write_settings(task.folder, legacy_stop_hook_stub(task.folder))
      File.write(File.join(File.dirname(settings), "commands.md"), "keep")

      launch_with_stubbed_spawn(task)

      refute File.exist?(settings)
      assert File.exist?(File.join(File.dirname(settings), "commands.md"))
    end
  end

  def test_launch_never_touches_project_owned_settings
    project_owned = [
      %({"enabledPlugins":{"frontend-design@official":true}}),
      JSON.generate("hooks" => { "Stop" => [ { "hooks" => [ { "type" => "command", "command" => "./my_hook.sh" } ] } ] }),
      JSON.generate(legacy_stop_hook_stub("/tmp/x").merge("model" => "opus")),
      JSON.generate("hooks" => { "Stop" => [ { "hooks" => [ { "type" => "command", "command" => "/opt/stop_hook.sh" } ] } ] }),
      JSON.generate("hooks" => "not-a-hash"),
      "[]",
      "{not json"
    ]
    project_owned.each do |content|
      with_tmp_task do |task|
        settings = write_settings(task.folder, content)

        launch_with_stubbed_spawn(task)

        assert_equal content, File.read(settings), "project-owned settings must survive: #{content}"
      end
    end
  end

  def test_repair_ignores_races_and_warns_when_it_cannot_write
    with_tmp_task do |task|
      settings = write_settings(task.folder, legacy_stop_hook_stub(task.folder))

      with_replaced_singleton_method(File, :delete, ->(_path) { raise Errno::ENOENT }) do
        assert_nil Hive::ClaudeLauncher.repair_legacy_scratch_settings([ task.folder ])
      end

      _out, err = capture_io do
        with_replaced_singleton_method(File, :delete, ->(_path) { raise Errno::EACCES }) do
          assert_nil Hive::ClaudeLauncher.repair_legacy_scratch_settings([ task.folder, nil ])
        end
      end
      assert_match(/could not repair legacy Claude settings #{Regexp.escape(settings)}: Errno::EACCES/, err)
    end
  end

  private

  def with_tmp_task(stage: "2-brainstorm")
    with_tmp_dir do |root|
      folder = File.join(root, ".hive-state", "stages", stage, "slug-260522-abcd")
      FileUtils.mkdir_p(folder)
      yield Hive::Task.new(folder)
    end
  end

  # Capture the original UnboundMethod and restore it via `define_method`
  # (Q1 / pr-test-analyzer #9). The earlier `define_singleton_method` lambda-rebind approach could
  # leak when minitest re-ordered tests; capturing the original
  # UnboundMethod and restoring it via `define_method` is symmetric
  # and survives reordering.
  def capture_unbound_method(method_name, original_unbound_or_method, &block)
    capture_unbound_method_on(Hive::ClaudeLauncher, method_name, original_unbound_or_method, &block)
  end

  def capture_unbound_method_on(mod, method_name, original_unbound_or_method)
    yield
  ensure
    if original_unbound_or_method.is_a?(UnboundMethod)
      mod.singleton_class.send(:define_method, method_name, original_unbound_or_method)
    elsif original_unbound_or_method.is_a?(Method)
      mod.define_singleton_method(method_name, original_unbound_or_method)
    end
  end

  # The exact settings.json the retired tmux StopHookInstaller wrote.
  def legacy_stop_hook_stub(stage_dir)
    command = "HIVE_TASK_STAGE_DIR=#{Shellwords.escape(stage_dir)} " \
              "#{Shellwords.escape('/opt/gems/hive-cli/lib/hive/scripts/stop_hook.sh')}"
    { "hooks" => { "Stop" => [ { "hooks" => [ { "type" => "command", "command" => command } ] } ] } }
  end

  def write_settings(dir, content)
    settings = File.join(dir, ".claude", "settings.json")
    FileUtils.mkdir_p(File.dirname(settings))
    File.write(settings, content.is_a?(String) ? content : JSON.pretty_generate(content) + "\n")
    settings
  end

  def launch_with_stubbed_spawn(task, cwd: task.folder)
    with_replaced_singleton_method(Hive::Stages::Base, :spawn_agent, ->(_task, **_kwargs) { { status: :complete } }) do
      Hive::ClaudeLauncher.launch!(
        task: task, cfg: {}, prompt: "prompt", add_dirs: [ task.folder ], cwd: cwd,
        max_budget_usd: 1, timeout_sec: 1, log_label: "test"
      )
    end
  end
end
