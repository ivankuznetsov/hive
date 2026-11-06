require "test_helper"
require "json"
require "hive/agent"
require "hive/agent_runtime"
require "hive/agent_support/muse"
require "hive/config"
require "hive/model_routing"
require "hive/task"

# Muse (`muse`) as a built-in Hive agent profile, exercised through the
# fake-muse fixture binary so argv, version, auth, stream, and usage
# behaviour are proven without a real Muse install or network.
class MuseAgentTest < Minitest::Test
  include HiveTestHelper

  FAKE_BIN = File.expand_path("../fixtures/fake-muse", __dir__)

  def setup
    @prev_bin = ENV["HIVE_MUSE_BIN"]
    ENV["HIVE_MUSE_BIN"] = FAKE_BIN
    Hive::AgentProfile.reset_version_cache!
  end

  def teardown
    ENV["HIVE_MUSE_BIN"] = @prev_bin
    %w[
      HIVE_FAKE_MUSE_VERSION HIVE_FAKE_MUSE_EXIT HIVE_FAKE_MUSE_FINAL
      HIVE_FAKE_MUSE_WRITE_FILE HIVE_FAKE_MUSE_WRITE_CONTENT
      HIVE_FAKE_MUSE_HANG HIVE_FAKE_MUSE_LOG_DIR HIVE_FAKE_MUSE_TERMINAL
      META_API_KEY
    ].each { |key| ENV.delete(key) }
    Hive::AgentProfile.reset_version_cache!
  end

  def make_task(dir)
    folder = File.join(dir, ".hive-state", "stages", "2-brainstorm", "muse-test")
    FileUtils.mkdir_p(folder)
    prepare_test_task_run(folder)
    Hive::Task.new(folder)
  end

  def profile(env: {})
    Hive::AgentProfiles.lookup(:muse).with_overrides(env)
  end

  def compile_argv(**kwargs)
    Hive::AgentRuntime.compile(
      Hive::AgentRuntime::Request.new(
        profile: Hive::AgentProfiles.lookup(:muse), prompt: "do the thing", **kwargs
      )
    ).argv
  end

  def test_muse_is_registered_without_changing_profile_order_or_defaults
    names = Hive::AgentProfiles.registered_names

    assert_equal :claude, names.first
    assert_equal :muse, names.last
    assert_includes names, :muse
    assert_equal "claude", Hive::Config::DEFAULTS.dig("brainstorm", "agent")
    assert_equal "claude", Hive::Config::DEFAULTS.dig("plan", "agent")
    assert_equal "claude", Hive::Config::DEFAULTS.dig("execute", "agent")
    assert_equal %w[claude codex], Hive::Config::DEFAULT_GLOBAL_AGENTS
    assert_includes Hive::Config::GLOBAL_AGENT_BACKENDS, "muse"
    assert_equal(
      { "bin" => "muse", "env_override" => "HIVE_MUSE_BIN", "min_version" => "1.4.14" },
      Hive::Config::DEFAULTS.dig("agents", "muse")
    )
  end

  def test_compile_uses_exec_json_with_prompt_on_stdin
    argv = compile_argv(model: "muse-fake-1", effort: "high")

    assert_equal FAKE_BIN, argv[0]
    assert_equal "exec", argv[1]
    assert_includes argv, "--prompt-file=/dev/stdin"
    refute_includes argv, "do the thing"
    assert_includes argv, "--yolo"
    assert_equal "muse-fake-1", argv[argv.index("--model") + 1]
    assert_equal "high", argv[argv.index("--reasoning-effort") + 1]
    assert_includes argv, "--json"
    assert_includes argv, "--disable-reminders"
    assert_includes argv, "--disable-request-user-input"
  end

  def test_compile_permission_modes_map_to_muse_sandbox_flags
    write = compile_argv(permission_mode: "workspace-write")
    assert_equal "never", write[write.index("--approval-mode") + 1]
    assert_includes write, "--trust-workspace"
    refute_includes write, "--yolo"
    refute_includes write, "--disable-write"

    read_only = compile_argv(permission_mode: "read-only")
    assert_includes read_only, "--disable-write"
    assert_includes read_only, "--disable-shell"
    refute_includes read_only, "--yolo"
  end

  def test_version_check_accepts_dual_form_version_output
    assert_equal "1.4.14", Hive::AgentProfiles.lookup(:muse).check_version!
  end

  def test_version_check_rejects_too_old_binary
    ENV["HIVE_FAKE_MUSE_VERSION"] = "1.3.0"

    error = assert_raises(Hive::AgentError) do
      Hive::AgentProfiles.lookup(:muse).check_version!
    end
    assert_match(/below minimum/, error.message)
  end

  def test_auth_probe_reads_xdg_auth_file_and_rejects_empty_stub
    with_tmp_dir do |home|
      runtime = Hive::AgentProfiles.lookup(:muse).runtime_profile
      xdg = File.join(home, "xdg")
      auth_dir = File.join(xdg, "muse")
      FileUtils.mkdir_p(auth_dir)
      env = { "HOME" => home, "XDG_CONFIG_HOME" => xdg }

      assert_equal :missing, runtime.auth_configuration(home:, env:).status
      File.write(File.join(auth_dir, "auth.json"), "{}")
      assert_equal :missing, runtime.auth_configuration(home:, env:).status
      File.write(File.join(auth_dir, "auth.json"), '{"token":"configured"}')
      assert_equal :configured, runtime.auth_configuration(home:, env:).status
      assert_equal File.join(xdg, "muse"),
                   runtime.configuration_directory(home:, env:)
    end
  end

  def test_prepare_fails_closed_without_a_subscription_session
    with_tmp_dir do |home|
      with_env("HOME" => home, "XDG_CONFIG_HOME" => File.join(home, "xdg")) do
        assert_raises(Hive::AgentRuntime::ProbeError) do
          Hive::AgentRuntime.prepare!(Hive::AgentProfiles.lookup(:muse))
        end
      end
    end
  end

  def test_prepare_does_not_treat_meta_api_key_as_a_subscription_session
    with_tmp_dir do |home|
      with_env(
        "HOME" => home, "XDG_CONFIG_HOME" => File.join(home, "xdg"),
        "META_API_KEY" => "unused-api-key"
      ) do
        assert_raises(Hive::AgentRuntime::ProbeError) do
          Hive::AgentRuntime.prepare!(Hive::AgentProfiles.lookup(:muse))
        end
      end
    end
  end

  def test_default_model_resolves_from_muse_settings
    with_tmp_dir do |home|
      settings = File.join(home, ".config", "muse", "settings.json")
      FileUtils.mkdir_p(File.dirname(settings))
      File.write(settings, JSON.generate("model" => "muse-fake-9"))

      assert_equal "muse-fake-9",
                   Hive::AgentProfiles.lookup(:muse)
                     .concrete_default_model(home: home)
    end
  end

  def test_routing_arguments_render_native_model_and_effort
    muse = Hive::AgentProfiles.lookup(:muse)
    resolution = Hive::ModelRouting.resolve(
      models: { "execute" => { "model" => "muse-fake-1", "effort" => "ultra" } },
      stage: "execute", provider: "muse"
    )

    arguments = muse.routing_arguments(resolution)

    assert_equal [ "--model", "muse-fake-1", "--reasoning-effort", "ultra" ],
                 arguments.native_arguments
  end

  def test_routing_rejects_unsupported_effort
    muse = Hive::AgentProfiles.lookup(:muse)
    resolution = Hive::ModelRouting.resolve(
      models: { "execute" => { "effort" => "ludicrous" } },
      stage: "execute", provider: "muse"
    )

    assert_raises(Hive::ConfigError) { muse.routing_arguments(resolution) }
  end

  def test_skill_verifier_searches_muse_skill_roots
    with_tmp_dir do |home|
      skill = File.join(home, ".config", "muse", "skills", "ce-plan", "SKILL.md")
      FileUtils.mkdir_p(File.dirname(skill))
      File.write(skill, "---\nname: ce-plan\n---\n")

      status, message = nil
      with_env("HOME" => home, "XDG_CONFIG_HOME" => File.join(home, ".config")) do
        status, message = Hive::AgentProfiles.lookup(:muse)
          .verify_skill("/ce-plan")
      end

      assert_equal :present, status
      assert_equal File.expand_path(skill), message
    end
  end

  def test_skill_verifier_reports_missing_skill_with_install_hint
    with_tmp_dir do |home|
      status, message = nil
      with_env("HOME" => home, "XDG_CONFIG_HOME" => File.join(home, ".config")) do
        status, message = Hive::AgentProfiles.lookup(:muse)
          .verify_skill("/ce-plan")
      end

      assert_equal :missing, status
      assert_includes message, "muse skills install"
    end
  end

  def test_sensitive_payload_fallback_scrubs_malformed_event_lines
    assert Hive::AgentSupport::Muse.sensitive_payload?(
      nil, raw_line: '{"payload_type":"run.output.delta","payload":"secret"}'
    )
    refute Hive::AgentSupport::Muse.sensitive_payload?(nil, raw_line: "ordinary output")
  end

  def test_spawn_records_terminal_message_usage_and_scrubbed_env
    with_tmp_dir do |dir|
      task = make_task(dir)
      log_dir = File.join(dir, "fake-log")
      output = File.join(dir, "findings.json")
      ENV["HIVE_FAKE_MUSE_LOG_DIR"] = log_dir
      ENV["HIVE_FAKE_MUSE_WRITE_FILE"] = output
      ENV["META_API_KEY"] = "must-not-reach-child"

      result = Hive::Agent.new(
        task: task, prompt: "secret prompt body", max_budget_usd: 1,
        timeout_sec: 10, profile: Hive::AgentProfiles.lookup(:muse),
        expected_output: output
      ).run!

      assert_equal :ok, result[:status], result.inspect
      assert_equal "fake muse final", result[:final_message]
      assert_equal :structured, result[:final_message_source]
      assert_equal 120, result[:usage][:input]
      assert_equal 45, result[:usage][:output]
      assert_equal "muse-fake-1", result[:usage][:model]

      argv_log = File.read(File.join(log_dir, "fake-muse-argv.log"))
      assert_includes argv_log, "arg=exec"
      assert_includes argv_log, "env_META_API_KEY=__unset__"

      log = File.read(result.fetch(:log_file))
      refute_includes log, "PROMPT-ECHO-MARKER"
      refute_includes log, "secret prompt body"
    end
  end

  def test_spawn_terminal_failure_event_is_an_error_despite_zero_exit
    with_tmp_dir do |dir|
      task = make_task(dir)
      ENV["HIVE_FAKE_MUSE_TERMINAL"] = "failed"
      output = File.join(dir, "findings.json")

      result = Hive::Agent.new(
        task: task, prompt: "x", max_budget_usd: 1, timeout_sec: 10,
        profile: Hive::AgentProfiles.lookup(:muse), expected_output: output
      ).run!

      assert_equal :error, result[:status], result.inspect
      assert_includes result[:error_message].to_s, "fake provider failure"
    end
  end

  def test_spawn_nonzero_exit_is_an_error
    with_tmp_dir do |dir|
      task = make_task(dir)
      ENV["HIVE_FAKE_MUSE_EXIT"] = "3"

      result = Hive::Agent.new(
        task: task, prompt: "x", max_budget_usd: 1, timeout_sec: 10,
        profile: Hive::AgentProfiles.lookup(:muse),
        expected_output: File.join(dir, "never-written.json")
      ).run!

      assert_equal :error, result[:status], result.inspect
      assert_equal 3, result[:exit_code]
    end
  end

  def test_spawn_timeout_kills_the_process_group
    with_tmp_dir do |dir|
      task = make_task(dir)
      ENV["HIVE_FAKE_MUSE_HANG"] = "30"

      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      result = Hive::Agent.new(
        task: task, prompt: "x", max_budget_usd: 1, timeout_sec: 1,
        profile: Hive::AgentProfiles.lookup(:muse),
        expected_output: File.join(dir, "never-written.json")
      ).run!
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

      assert_equal :timeout, result[:status], result.inspect
      assert_operator elapsed, :<, 15
    end
  end
  def test_sensitive_payload_covers_parsed_events_and_raw_lines
    muse = Hive::AgentSupport::Muse

    muse::SENSITIVE_PAYLOAD_TYPES.each do |type|
      assert muse.sensitive_payload?({ "payload_type" => type }), type
      raw = %({"seq":1,"payload_type" : "#{type}","payload":{"text":"secret)
      assert muse.sensitive_payload?(nil, raw_line: raw), "truncated raw #{type}"
    end
    %w[run.usage run.terminal.failed task.lifecycle.failed].each do |type|
      refute muse.sensitive_payload?({ "payload_type" => type }), type
      refute muse.sensitive_payload?(nil, raw_line: %({"payload_type":"#{type}"})), type
    end
    refute muse.sensitive_payload?(nil, raw_line: nil)
    refute muse.sensitive_payload?(nil, raw_line: "plain \xFF stderr".b)
  end

  def test_extract_message_takes_only_non_blank_completed_terminal_text
    muse = Hive::AgentSupport::Muse
    completed = ->(payload) { { "payload_type" => "run.terminal.completed", "payload" => payload } }

    assert_equal "done", muse.extract_message(completed.call({ "text" => "done" }))
    assert_nil muse.extract_message(completed.call({ "text" => "  \n" }))
    assert_nil muse.extract_message(completed.call({ "text" => 42 }))
    assert_nil muse.extract_message(completed.call("done"))
    assert_nil muse.extract_message({ "payload_type" => "run.output.delta", "payload" => { "text" => "x" } })
  end
  def test_open_pr_reuses_the_execute_model_only_on_the_same_provider
    muse = Hive::AgentSupport::Muse

    assert_equal [ "muse-wonder-1.0", true ],
                 muse.downstream_model(stage: "open_pr", execute_identity: { "model" => "muse-wonder-1.0" },
                                       provider_changed: false)
    assert_nil muse.downstream_model(stage: "open_pr", execute_identity: { "model" => "muse-wonder-1.0" },
                                     provider_changed: true)
    assert_nil muse.downstream_model(stage: "review.fix", execute_identity: { "model" => "muse-wonder-1.0" },
                                     provider_changed: false)
    assert_nil muse.downstream_model(stage: "open_pr", execute_identity: { model: "" }, provider_changed: false)
  end
end
