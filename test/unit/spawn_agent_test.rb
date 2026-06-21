require "test_helper"
require "hive/markers"
require "hive/lock"
require "hive/config"
require "hive/task"
require "hive/agent"
require "hive/agent_profiles"
require "hive/claude_launcher"
require "hive/stages/base"

# Direct coverage for Hive::Stages::Base.spawn_agent: profile check_version! /
# preflight! ordering, the warn_isolation_reduced trigger when the configured
# profile lacks add_dir_flag, and the default-profile fallback. Closes
# doc-review #11 (spawn_agent has zero direct tests) and #10
# (warn_isolation_reduced has zero tests).
class SpawnAgentTest < Minitest::Test
  include HiveTestHelper

  FAKE_BIN = File.expand_path("../fixtures/fake-claude", __dir__)

  def setup
    @prev_bin = ENV["HIVE_CLAUDE_BIN"]
    ENV["HIVE_CLAUDE_BIN"] = FAKE_BIN
    Hive::AgentProfile.reset_version_cache!
  end

  def teardown
    ENV["HIVE_CLAUDE_BIN"] = @prev_bin
    %w[HIVE_FAKE_CLAUDE_OUTPUT HIVE_FAKE_CLAUDE_EXIT
       HIVE_FAKE_CLAUDE_WRITE_FILE HIVE_FAKE_CLAUDE_WRITE_CONTENT
       HIVE_FAKE_CLAUDE_HANG HIVE_FAKE_CLAUDE_LOG_DIR
       HIVE_FAKE_CLAUDE_VERSION].each { |k| ENV.delete(k) }
    Hive::AgentProfile.reset_version_cache!
  end

  def make_task(dir, stage = "2-brainstorm", slug = "spawn-test-260425-aaaa")
    folder = File.join(dir, ".hive-state", "stages", stage, slug)
    FileUtils.mkdir_p(folder)
    Hive::Task.new(folder)
  end

  # --- resolve_template_path ----------------------------------------------

  def test_resolve_template_path_rejects_missing_builtin
    error = assert_raises(Hive::ConfigError) do
      Hive::Stages::Base.resolve_template_path("missing-template.erb")
    end

    assert_match(/not found among built-ins/, error.message)
  end

  def test_resolve_template_path_rejects_custom_without_state_dir
    error = assert_raises(Hive::ConfigError) do
      Hive::Stages::Base.resolve_template_path("./custom-prompt.md")
    end

    assert_match(/custom path but no hive_state_dir/, error.message)
  end

  def test_resolve_template_path_rejects_symlink_escape
    with_tmp_dir do |dir|
      state_dir = File.join(dir, ".hive-state")
      templates_dir = File.join(state_dir, "templates")
      FileUtils.mkdir_p(templates_dir)
      outside = File.join(dir, "outside.md")
      File.write(outside, "outside prompt\n")
      File.symlink(outside, File.join(templates_dir, "escape.md"))

      error = assert_raises(Hive::ConfigError) do
        Hive::Stages::Base.resolve_template_path("./escape.md", hive_state_dir: state_dir)
      end

      assert_match(/resolves outside/, error.message)
    end
  end

  # --- default profile selection ------------------------------------------

  def test_default_profile_is_claude
    with_tmp_dir do |dir|
      task = make_task(dir)
      File.write(task.state_file, "<!-- WAITING -->\n")
      log_dir = Dir.mktmpdir("fake-claude-argv")
      ENV["HIVE_FAKE_CLAUDE_LOG_DIR"] = log_dir
      Hive::Stages::Base.spawn_agent(
        task,
        prompt: "x",
        max_budget_usd: 1,
        timeout_sec: 5
        # no profile: kwarg
      )
      argv = File.read(File.join(log_dir, "fake-claude-argv.log"))
      # claude-specific flags must appear
      assert_includes argv, "arg=--dangerously-skip-permissions"
      assert_includes argv, "arg=--no-session-persistence"
    ensure
      FileUtils.rm_rf(log_dir) if log_dir
    end
  end

  def test_claude_permission_mode_from_cfg_reaches_headless_spawn
    with_tmp_dir do |dir|
      task = make_task(dir)
      File.write(task.state_file, "<!-- WAITING -->\n")
      log_dir = Dir.mktmpdir("fake-claude-argv")
      ENV["HIVE_FAKE_CLAUDE_LOG_DIR"] = log_dir
      Hive::Stages::Base.spawn_agent(
        task,
        prompt: "x",
        max_budget_usd: 1,
        timeout_sec: 5,
        cfg: { "claude" => { "permission_mode" => "auto" } }
      )
      argv = File.read(File.join(log_dir, "fake-claude-argv.log"))
      assert_includes argv, "arg=--permission-mode"
      assert_includes argv, "arg=auto"
      refute_includes argv, "arg=--dangerously-skip-permissions"
    ensure
      FileUtils.rm_rf(log_dir) if log_dir
    end
  end

  def test_tool_scope_kwargs_reach_headless_claude_spawn
    with_tmp_dir do |dir|
      task = make_task(dir)
      File.write(task.state_file, "<!-- WAITING -->\n")
      log_dir = Dir.mktmpdir("fake-claude-argv")
      ENV["HIVE_FAKE_CLAUDE_LOG_DIR"] = log_dir
      Hive::Stages::Base.spawn_agent(
        task,
        prompt: "x",
        max_budget_usd: 1,
        timeout_sec: 5,
        allowed_tools: %w[Read LS],
        disallowed_tools: %w[Write Bash]
      )

      argv = File.read(File.join(log_dir, "fake-claude-argv.log"))
      assert_includes argv, "arg=--allowedTools"
      assert_includes argv, "arg=Read,LS"
      assert_includes argv, "arg=--disallowedTools"
      assert_includes argv, "arg=Write,Bash"
    ensure
      FileUtils.rm_rf(log_dir) if log_dir
    end
  end

  # claude.permission_mode is a Claude-only setting. A non-claude (codex)
  # profile spawn that now receives cfg: (rebase / reviewers all thread it
  # through) must NOT gain a --permission-mode flag;
  # it keeps its own skip flag. Guards the `profile.name == :claude` gate in
  # spawn_agent so the new cfg threading can't leak Claude flags into codex.
  def test_codex_profile_with_cfg_does_not_receive_permission_mode_flags
    with_tmp_dir do |dir|
      task = make_task(dir)
      File.write(task.state_file, "<!-- WAITING -->\n")
      argv_log = File.join(dir, "codex-argv.log")
      fake_codex = File.join(dir, "fake-codex")
      File.write(fake_codex, <<~SH)
        #!/usr/bin/env bash
        if [ "$1" = "--version" ]; then echo "codex-cli 1.0.0"; exit 0; fi
        printf '%s\n' "$@" > "#{argv_log}"
        cat > /dev/null
        exit 0
      SH
      File.chmod(0o755, fake_codex)
      profile = Hive::AgentProfile.new(
        name: :codex,
        bin_default: fake_codex,
        headless_flag: "exec",
        version_flag: "--version",
        permission_skip_flag: "--dangerously-bypass-approvals-and-sandbox",
        skill_syntax_format: "/%{skill}",
        status_detection_mode: :exit_code_only
      )

      Hive::Stages::Base.spawn_agent(
        task,
        prompt: "x",
        max_budget_usd: 1,
        timeout_sec: 5,
        profile: profile,
        status_mode: :exit_code_only,
        cfg: { "claude" => { "permission_mode" => "auto" } }
      )

      argv = File.read(argv_log).lines.map(&:chomp)
      refute_includes argv, "--permission-mode",
                       "codex spawns must never receive Claude's --permission-mode flag"
      refute_includes argv, "auto"
      assert_includes argv, "--dangerously-bypass-approvals-and-sandbox",
                      "codex keeps its own skip flag regardless of claude.permission_mode in cfg"
    end
  end

  # --- preflight ordering --------------------------------------------------

  def test_preflight_runs_before_agent_spawn_returns_error_envelope
    # Build a profile whose preflight raises; assert spawn_agent
    # converts it to a typed :error envelope (REL1 — closes
    # ce-code-review reliability finding) instead of letting the
    # exception escape. Callers see :error → write a properly-attributed
    # REVIEW_ERROR with reason="agent_preflight_failed".
    raising_profile = Hive::AgentProfile.new(
      name: :raises_preflight,
      bin_default: FAKE_BIN,
      env_bin_override_key: "HIVE_CLAUDE_BIN",
      headless_flag: "-p",
      output_format_flags: [ "--verbose" ],
      version_flag: "--version",
      skill_syntax_format: "/%{skill}",
      status_detection_mode: :state_file_marker,
      preflight: -> { raise Hive::AgentError, "preflight blocked" }
    )

    with_tmp_dir do |dir|
      task = make_task(dir)
      File.write(task.state_file, "<!-- WAITING -->\n")
      log_dir = Dir.mktmpdir("no-spawn-argv")
      ENV["HIVE_FAKE_CLAUDE_LOG_DIR"] = log_dir

      result = Hive::Stages::Base.spawn_agent(
        task,
        prompt: "x", max_budget_usd: 1, timeout_sec: 5,
        profile: raising_profile
      )
      assert_equal :error, result[:status]
      assert_match(/preflight failed/, result[:error_message])
      assert_match(/preflight blocked/, result[:error_message])

      # No argv log written → no spawn happened.
      argv_log = File.join(log_dir, "fake-claude-argv.log")
      refute File.exist?(argv_log),
             "agent must not spawn when preflight raises"
    ensure
      FileUtils.rm_rf(log_dir) if log_dir
    end
  end

  def test_check_version_failure_returns_error_envelope
    # When the version check raises (e.g., binary missing or below
    # min_version), spawn_agent must translate to {status: :error}
    # rather than re-raising, mirroring the preflight! handling.
    failing_profile = Hive::AgentProfile.new(
      name: :version_too_old,
      bin_default: FAKE_BIN,
      env_bin_override_key: "HIVE_CLAUDE_BIN",
      headless_flag: "-p",
      output_format_flags: [ "--verbose" ],
      version_flag: "--version",
      skill_syntax_format: "/%{skill}",
      status_detection_mode: :state_file_marker,
      min_version: "99.99.99"
    )

    with_tmp_dir do |dir|
      task = make_task(dir)
      File.write(task.state_file, "<!-- WAITING -->\n")
      log_dir = Dir.mktmpdir("no-spawn-argv")
      ENV["HIVE_FAKE_CLAUDE_LOG_DIR"] = log_dir
      ENV["HIVE_FAKE_CLAUDE_VERSION"] = "1.0.0" # below 99.99.99

      result = Hive::Stages::Base.spawn_agent(
        task,
        prompt: "x", max_budget_usd: 1, timeout_sec: 5,
        profile: failing_profile
      )
      assert_equal :error, result[:status]
      assert_match(/preflight failed/, result[:error_message])
      assert_match(/below minimum/, result[:error_message])

      argv_log = File.join(log_dir, "fake-claude-argv.log")
      refute File.exist?(argv_log),
             "agent must not spawn when check_version! fails"
    ensure
      FileUtils.rm_rf(log_dir) if log_dir
    end
  end

  # --- warn_isolation_reduced --------------------------------------------

  def test_isolation_warning_written_when_profile_lacks_add_dir_flag
    # Profile with no add_dir_flag, claude bin (so it actually runs).
    no_add_dir_profile = Hive::AgentProfile.new(
      name: :no_isolation,
      bin_default: FAKE_BIN,
      env_bin_override_key: "HIVE_CLAUDE_BIN",
      headless_flag: "-p",
      add_dir_flag: nil, # the gap under test
      output_format_flags: [ "--verbose" ],
      version_flag: "--version",
      skill_syntax_format: "/%{skill}",
      status_detection_mode: :state_file_marker
    )

    with_tmp_dir do |dir|
      task = make_task(dir)
      File.write(task.state_file, "<!-- WAITING -->\n")
      Hive::Stages::Base.spawn_agent(
        task,
        prompt: "x", max_budget_usd: 1, timeout_sec: 5,
        add_dirs: [ dir ],
        profile: no_add_dir_profile
      )

      log_path = File.join(task.log_dir, "isolation-warnings.log")
      assert File.exist?(log_path), "isolation-warnings.log must be written"
      content = File.read(log_path)
      assert_match(/profile :no_isolation has no add_dir_flag/, content)
      assert_match(/ADR-018/, content)
      assert_includes content, dir, "log must cite the ignored add_dirs"
    end
  end

  def test_no_isolation_warning_when_profile_has_add_dir_flag
    # Default claude profile has --add-dir; passing add_dirs is fine.
    with_tmp_dir do |dir|
      task = make_task(dir)
      File.write(task.state_file, "<!-- WAITING -->\n")
      Hive::Stages::Base.spawn_agent(
        task,
        prompt: "x", max_budget_usd: 1, timeout_sec: 5,
        add_dirs: [ dir ]
        # default claude profile
      )
      log_path = File.join(task.log_dir, "isolation-warnings.log")
      refute File.exist?(log_path),
             "no warning expected when profile has add_dir_flag"
    end
  end

  def test_isolation_warning_rejects_non_array_add_dirs
    no_add_dir_profile = Hive::AgentProfile.new(
      name: :no_isolation,
      bin_default: FAKE_BIN,
      env_bin_override_key: "HIVE_CLAUDE_BIN",
      headless_flag: "-p",
      output_format_flags: [ "--verbose" ],
      version_flag: "--version",
      skill_syntax_format: "/%{skill}",
      status_detection_mode: :state_file_marker
    )

    with_tmp_dir do |dir|
      task = make_task(dir)
      File.write(task.state_file, "<!-- WAITING -->\n")
      err = assert_raises(ArgumentError) do
        # spawn_agent's signature requires Array; pass through warn helper.
        Hive::Stages::Base.send(
          :warn_isolation_reduced,
          task, no_add_dir_profile, { wrong: "type" }
        )
      end
      assert_match(/Array/, err.message)
    end
  end

  def test_isolation_warning_falls_back_to_stderr_when_log_path_is_unwritable
    with_tmp_dir do |dir|
      blocked_log_dir = File.join(dir, "blocked-log-dir")
      File.write(blocked_log_dir, "not a directory\n")
      task = Object.new
      task.define_singleton_method(:log_dir) { blocked_log_dir }
      profile = Object.new
      profile.define_singleton_method(:name) { :no_isolation }

      _out, err = capture_io do
        Hive::Stages::Base.send(:warn_isolation_reduced, task, profile, [ dir ])
      end

      assert_match(/agent profile :no_isolation has no add_dir_flag/, err)
      assert_match(/filesystem-isolation boundary is reduced/, err)
    end
  end

  # --- cross-spawn nonce isolation property -----------------------------

  def test_cross_spawn_nonce_isolation_two_distinct_renders
    # The SEC-1 fix's security property: a leaked nonce in one render cannot
    # forge a closing tag against any sibling render. Verify by rendering
    # the same template twice with separately-fetched tags and asserting:
    # (a) tags differ, (b) one render's close-tag does not match the other's
    # nonce, (c) the literal hostile string `</user_supplied>` (no nonce)
    # would not match either render's close-tag.
    tag_a = Hive::Stages::Base.user_supplied_tag
    tag_b = Hive::Stages::Base.user_supplied_tag

    refute_equal tag_a, tag_b, "per-spawn nonces must be fresh per call"

    open_a, close_a = "<#{tag_a}>", "</#{tag_a}>"
    open_b, close_b = "<#{tag_b}>", "</#{tag_b}>"

    refute_equal close_a, close_b, "close tags must be distinct per spawn"
    refute open_a.include?(tag_b), "spawn-A's open must not contain spawn-B's nonce"
    refute close_a.include?(tag_b), "spawn-A's close must not contain spawn-B's nonce"

    # Naive hostile literal — no per-render nonce attached. Must not match
    # either close tag.
    naive_hostile = "</user_supplied>"
    refute_equal naive_hostile, close_a
    refute_equal naive_hostile, close_b
  end

  # --- stage_profile: reads cfg[stage].agent with claude fallback ---------

  def test_stage_profile_falls_back_to_claude_when_key_absent
    cfg = {}
    profile = Hive::Stages::Base.stage_profile(cfg, "brainstorm")
    assert_equal :claude, profile.name
  end

  def test_stage_profile_resolves_configured_agent_name
    cfg = { "brainstorm" => { "agent" => "codex" } }
    profile = Hive::Stages::Base.stage_profile(cfg, "brainstorm")
    assert_equal :codex, profile.name
  end

  def test_stage_profile_independently_resolved_per_stage
    cfg = {
      "brainstorm" => { "agent" => "claude" },
      "plan"       => { "agent" => "codex" },
      "execute"    => { "agent" => "pi" }
    }
    assert_equal :claude, Hive::Stages::Base.stage_profile(cfg, "brainstorm").name
    assert_equal :codex,  Hive::Stages::Base.stage_profile(cfg, "plan").name
    assert_equal :pi,     Hive::Stages::Base.stage_profile(cfg, "execute").name
  end

  def test_stage_profile_honors_per_cli_overrides_under_agents_block
    # cfg.agents.<name>.bin override flows through AgentProfiles.lookup and
    # produces a profile whose bin reflects the override. Used by tests and
    # non-default per-project binary pinning.
    cfg = {
      "execute" => { "agent" => "codex" },
      "agents"  => { "codex" => { "bin" => "/custom/codex/path" } }
    }
    profile = Hive::Stages::Base.stage_profile(cfg, "execute")
    assert_equal :codex, profile.name
    assert_equal "/custom/codex/path", profile.bin
  end

  def test_stage_profile_raises_on_unknown_agent_name
    # Config.load's validate_role_agent_names! already prevents this case
    # for project configs, but the helper itself must surface the error
    # rather than returning a nil profile silently — protects callers that
    # pass synthetic cfg hashes (e.g. tests, future hive-config CLI).
    cfg = { "brainstorm" => { "agent" => "no_such_agent" } }
    assert_raises(Hive::AgentProfiles::UnknownAgent) do
      Hive::Stages::Base.stage_profile(cfg, "brainstorm")
    end
  end

  def test_stage_permission_scope_yolo_preserves_headless_no_tool_lists
    with_tmp_dir do |dir|
      task = make_task(dir, "3-plan")
      cfg = { "permissions" => "yolo", "claude" => { "mode" => "headless" } }

      scope = Hive::Stages::Base.stage_permission_scope(
        cfg, "plan", task, Hive::AgentProfiles.lookup(:claude),
        default_allowed_tools: Hive::ClaudeLauncher::PLANNER_ALLOWED_TOOLS
      )

      assert_equal [ task.folder ], scope.fetch(:add_dirs)
      assert_nil scope.fetch(:permission_mode)
      assert_nil scope.fetch(:allowed_tools)
      assert_nil scope.fetch(:disallowed_tools)
    end
  end

  def test_stage_permission_scope_yolo_preserves_tmux_builtin_allowlist
    with_tmp_dir do |dir|
      task = make_task(dir, "3-plan")
      cfg = { "permissions" => "yolo", "claude" => { "mode" => "tmux" } }

      scope = Hive::Stages::Base.stage_permission_scope(
        cfg, "plan", task, Hive::AgentProfiles.lookup(:claude),
        default_allowed_tools: Hive::ClaudeLauncher::PLANNER_ALLOWED_TOOLS
      )

      assert_equal Hive::ClaudeLauncher::PLANNER_ALLOWED_TOOLS, scope.fetch(:allowed_tools)
      assert_nil scope.fetch(:permission_mode)
      assert_nil scope.fetch(:disallowed_tools)
    end
  end

  def test_stage_permission_scope_read_only_overrides_builtin_tools
    with_tmp_dir do |dir|
      task = make_task(dir, "3-plan")
      cfg = {
        "permissions" => "yolo",
        "claude" => { "mode" => "tmux" },
        "plan" => { "permissions" => "read-only" }
      }

      scope = Hive::Stages::Base.stage_permission_scope(
        cfg, "plan", task, Hive::AgentProfiles.lookup(:claude),
        default_allowed_tools: Hive::ClaudeLauncher::PLANNER_ALLOWED_TOOLS
      )

      assert_equal "default", scope.fetch(:permission_mode)
      assert_equal %w[Read LS Grep Glob], scope.fetch(:allowed_tools)
      assert_equal %w[Write Edit MultiEdit NotebookEdit Bash], scope.fetch(:disallowed_tools)
    end
  end

  def test_stage_permission_scope_scoped_appends_extra_dirs
    with_tmp_dir do |dir|
      task = make_task(dir, "4-execute")
      absolute = File.join(dir, "abs")
      cfg = {
        "permissions" => "yolo",
        "claude" => { "mode" => "headless" },
        "execute" => {
          "permissions" => {
            "preset" => "scoped",
            "tools" => %w[Read Write Edit],
            "dirs" => [ "./drafts", absolute ]
          }
        }
      }

      scope = Hive::Stages::Base.stage_permission_scope(
        cfg, "execute", task, Hive::AgentProfiles.lookup(:claude),
        base_add_dirs: [ task.folder ],
        default_allowed_tools: Hive::ClaudeLauncher::IMPLEMENTER_ALLOWED_TOOLS
      )

      assert_equal [ task.folder, File.join(task.folder, "drafts"), absolute ], scope.fetch(:add_dirs)
      assert_equal %w[Read Write Edit], scope.fetch(:allowed_tools)
    end
  end

  # A7 golden: pin the actual emitted argv for the absent-permissions
  # (yolo) plan stage in BOTH modes, threading stage_permission_scope's
  # output through the real argv builders. The scope-dict tests above
  # prove the dict; this proves the dict reaches the command line
  # byte-for-byte — so a stage that dropped the tmux builtin allowlist or
  # leaked a tool-scope flag into the headless yolo path would fail here.
  def test_yolo_plan_argv_is_byte_identical_to_legacy_in_both_modes
    with_tmp_dir do |dir|
      task = make_task(dir, "3-plan")
      profile = Hive::AgentProfiles.lookup(:claude)

      headless_cfg = {
        "permissions" => "yolo",
        "claude" => { "mode" => "headless", "permission_mode" => "bypassPermissions" }
      }
      headless_scope = Hive::Stages::Base.stage_permission_scope(
        headless_cfg, "plan", task, profile,
        default_allowed_tools: Hive::ClaudeLauncher::PLANNER_ALLOWED_TOOLS
      )
      agent = Hive::Agent.new(
        task: task, prompt: "PROMPT", max_budget_usd: 1, timeout_sec: 5,
        profile: profile,
        add_dirs: headless_scope.fetch(:add_dirs),
        permission_mode: headless_scope.fetch(:permission_mode),
        allowed_tools: headless_scope.fetch(:allowed_tools),
        disallowed_tools: headless_scope.fetch(:disallowed_tools)
      )
      expected_headless = [
        profile.bin, "-p", "--dangerously-skip-permissions",
        "--add-dir", task.folder,
        "--max-budget-usd", "1",
        "--output-format", "stream-json", "--include-partial-messages",
        "--verbose", "--no-session-persistence",
        "PROMPT"
      ]
      assert_equal expected_headless, agent.send(:build_cmd),
                   "yolo headless argv must carry no tool-scope flags"

      tmux_cfg = {
        "permissions" => "yolo",
        "claude" => { "mode" => "tmux", "permission_mode" => "bypassPermissions" }
      }
      tmux_scope = Hive::Stages::Base.stage_permission_scope(
        tmux_cfg, "plan", task, profile,
        default_allowed_tools: Hive::ClaudeLauncher::PLANNER_ALLOWED_TOOLS
      )
      wrapper = Hive::ClaudeLauncher.wrapper_command(
        cwd: task.folder,
        add_dirs: tmux_scope.fetch(:add_dirs),
        profile: profile,
        permission_mode: tmux_scope.fetch(:permission_mode) || Hive::Config.claude_permission_mode(tmux_cfg),
        allowed_tools: tmux_scope.fetch(:allowed_tools),
        disallowed_tools: tmux_scope.fetch(:disallowed_tools)
      )
      # tmux yolo keeps the builtin allowlist threaded and emits NO deny
      # list — the exact "forgot to thread default_allowed_tools" regression.
      assert_equal [ "--allowedTools", Hive::ClaudeLauncher::PLANNER_ALLOWED_TOOLS ],
                   wrapper.each_cons(2).find { |a, _| a == "--allowedTools" }
      assert_includes wrapper, "--dangerously-skip-permissions"
      refute_includes wrapper, "--disallowedTools"
    end
  end

  def test_stage_permission_scope_rejects_non_claude_non_yolo
    with_tmp_dir do |dir|
      task = make_task(dir, "4-execute")
      cfg = {
        "permissions" => "yolo",
        "execute" => { "permissions" => "read-only" }
      }

      error = assert_raises(Hive::ConfigError) do
        Hive::Stages::Base.stage_permission_scope(
          cfg, "execute", task, Hive::AgentProfiles.lookup(:codex)
        )
      end

      assert_match(/stage execute requests permissions/, error.message)
      assert_match(/runner :codex/, error.message)
    end
  end

  # The A8 runner-gate raise must land an attributed :error marker on the
  # stage's own task before it propagates — not escape uncaught and leave
  # the prior marker (e.g. AGENT_WORKING) stale (plan U10-4). Every
  # single-agent stage routes its scope resolution through this helper, so
  # one test pins the whole class across codex and pi.
  def test_stage_permission_scope_or_mark_attributes_error_marker_for_non_claude
    %i[codex pi].each do |runner|
      with_tmp_dir do |dir|
        task = make_task(dir, "4-execute")
        # Simulate the stale in-progress marker the runner leaves before
        # the spawn helper resolves the scope.
        Hive::Markers.set(task.state_file, :agent_working)
        cfg = {
          "permissions" => "yolo",
          "execute" => { "permissions" => "read-only" }
        }

        error = assert_raises(Hive::ConfigError) do
          Hive::Stages::Base.stage_permission_scope_or_mark!(
            cfg, "execute", task, Hive::AgentProfiles.lookup(runner)
          )
        end
        assert_match(/runner #{runner.inspect}/, error.message)

        marker = Hive::Markers.current(task.state_file)
        assert_equal :error, marker.name, "#{runner} must leave an attributed :error marker"
        assert_equal "permission_config_error", marker.attrs["reason"]
        assert_match(/claude only/, marker.attrs["message"].to_s)
      end
    end
  end
end
