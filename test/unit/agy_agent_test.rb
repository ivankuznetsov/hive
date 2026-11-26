require "test_helper"
require "json"
require "hive/agent"
require "hive/agent_runtime"
require "hive/config"
require "hive/implementation_identity/utility_models"
require "hive/model_routing"
require "hive/plan_review/planner_identity"
require "hive/task"
require "hive/stages/base"

# Antigravity CLI (`agy`) as a built-in Hive agent profile, exercised through
# the fake-agy fixture binary so argv, version, auth, settings model
# normalization, skill roots, stream metering, and spawn lifecycle are proven
# hermetically.
class AgyAgentTest < Minitest::Test
  include HiveTestHelper

  FAKE_BIN = File.expand_path("../fixtures/fake-agy", __dir__)

  def setup
    @prev_bin = ENV["HIVE_AGY_BIN"]
    ENV["HIVE_AGY_BIN"] = FAKE_BIN
    Hive::AgentProfile.reset_version_cache!
  end

  def teardown
    ENV["HIVE_AGY_BIN"] = @prev_bin
    %w[
      HIVE_FAKE_AGY_VERSION HIVE_FAKE_AGY_EXIT HIVE_FAKE_AGY_FINAL
      HIVE_FAKE_AGY_WRITE_FILE HIVE_FAKE_AGY_WRITE_CONTENT
      HIVE_FAKE_AGY_HANG HIVE_FAKE_AGY_LOG_DIR HIVE_FAKE_AGY_RESULT
      HIVE_FAKE_AGY_ERROR HIVE_FAKE_AGY_MODEL
      GEMINI_API_KEY GOOGLE_API_KEY GOOGLE_APPLICATION_CREDENTIALS
    ].each { |key| ENV.delete(key) }
    Hive::AgentProfile.reset_version_cache!
  end

  def make_task(dir)
    folder = File.join(dir, ".hive-state", "stages", "2-brainstorm", "agy-test")
    FileUtils.mkdir_p(folder)
    prepare_test_task_run(folder)
    Hive::Task.new(folder)
  end

  def compile_invocation(**kwargs)
    Hive::AgentRuntime.compile(
      Hive::AgentRuntime::Request.new(
        profile: Hive::AgentProfiles.lookup(:agy), prompt: "do the thing", **kwargs
      )
    )
  end

  def test_agy_is_registered_without_changing_profile_order_or_defaults
    names = Hive::AgentProfiles.registered_names

    assert_equal :claude, names.first
    assert_equal :agy, names.last
    assert_includes names, :agy
    assert_equal "claude", Hive::Config::DEFAULTS.dig("brainstorm", "agent")
    assert_equal "claude", Hive::Config::DEFAULTS.dig("plan", "agent")
    assert_equal "/ce-plan", Hive::Config::DEFAULTS.dig("plan", "skill_by_agent", "agy")
    assert_equal "claude", Hive::Config::DEFAULTS.dig("execute", "agent")
    assert_equal %w[claude codex], Hive::Config::DEFAULT_GLOBAL_AGENTS
    assert_includes Hive::Config::GLOBAL_AGENT_BACKENDS, "agy"
    assert_equal(
      { "bin" => "agy", "env_override" => "HIVE_AGY_BIN", "min_version" => "1.5.17" },
      Hive::Config::DEFAULTS.dig("agents", "agy")
    )
    assert_equal({ model: nil, pin_model: false },
                 Hive::ImplementationIdentity::UtilityModels.resolve(:agy))
    assert_equal "google", Hive::PlanReview::PlannerIdentity.family(:agy)
  end

  def test_compile_uses_stdin_input_and_stream_json_output
    invocation = compile_invocation(
      add_dirs: [ "/tmp/task-dir" ], model: "gemini-4-neon-xhigh", effort: "xhigh"
    )
    argv = invocation.argv

    assert_equal FAKE_BIN, argv[0]
    assert_equal "--input-format=text", argv[1]
    assert_includes argv, "--dangerously-skip-permissions"
    assert_equal "/tmp/task-dir", argv[argv.index("--add-dir") + 1]
    assert_equal "gemini-4-neon-xhigh", argv[argv.index("--model") + 1]
    assert_equal "xhigh", argv[argv.index("--effort") + 1]
    assert_equal "stream-json", argv[argv.index("--output-format") + 1]
    refute_includes argv, "do the thing"
    assert_equal "do the thing", invocation.stdin_data
  end

  def test_scoped_sandbox_modes_fail_closed
    agy = Hive::AgentProfiles.lookup(:agy)

    refute agy.workspace_write_supported?
    refute agy.read_only_supported?
    %w[workspace-write read-only].each do |mode|
      assert_raises(Hive::AgentRuntime::UnsupportedCapability) do
        compile_invocation(permission_mode: mode)
      end
    end
  end

  def test_version_check_accepts_minimum_and_rejects_older
    assert_equal "1.5.17", Hive::AgentProfiles.lookup(:agy).check_version!

    Hive::AgentProfile.reset_version_cache!
    ENV["HIVE_FAKE_AGY_VERSION"] = "1.5.0"
    error = assert_raises(Hive::AgentError) do
      Hive::AgentProfiles.lookup(:agy).check_version!
    end
    assert_match(/below minimum/, error.message)
  end

  def test_logged_in_probes_oauth_token_including_binary_bytes
    with_tmp_dir do |home|
      refute Hive::AgentProfiles.logged_in?(:agy, home: home)

      token = File.join(home, ".gemini", "antigravity-cli", "antigravity-oauth-token")
      FileUtils.mkdir_p(File.dirname(token))
      File.write(token, "{}")
      refute Hive::AgentProfiles.logged_in?(:agy, home: home)

      File.binwrite(token, "\x80\xFFopaque-oauth-token".b)
      assert Hive::AgentProfiles.logged_in?(:agy, home: home)
    end
  end

  def test_prepare_succeeds_without_fallback_token_file_for_os_keyring_hosts
    with_tmp_dir do |home|
      with_env("HOME" => home) do
        probe = Hive::AgentRuntime.prepare!(Hive::AgentProfiles.lookup(:agy))
        assert_equal :agy, probe.provider
        assert_equal "1.5.17", probe.version
      end
    end
  end

  def test_default_model_resolves_and_normalizes_display_names_from_settings
    samples = {
      "gemini-4-neon-xhigh" => "gemini-4-neon-xhigh",
      "Gemini 4 Neon (XHigh)" => "gemini-4-neon-xhigh",
      "Gemini 3.8 Flash (Low)" => "gemini-3.8-flash-low",
      "Claude Opus 5.5 (High)" => "claude-opus-5-5-high",
      "GPT-OSS 120B (Medium)" => "gpt-oss-120b-medium",
      "Orchestrator (Carbon)" => "gemini-pro-orchestrator",
      "Orchestrator (Neon)" => "gemini-pro-orchestrator-neon",
      "Orchestrator (Argon)" => "gemini-pro-orchestrator-argon"
    }

    samples.each do |raw, expected|
      with_tmp_dir do |home|
        settings = File.join(home, ".gemini", "antigravity-cli", "settings.json")
        FileUtils.mkdir_p(File.dirname(settings))
        File.write(settings, JSON.generate("model" => raw))

        assert_equal expected,
                     Hive::AgentProfiles.lookup(:agy).concrete_default_model(home: home),
                     "expected #{raw.inspect} to normalize to #{expected.inspect}"
      end
    end
  end

  def test_routing_arguments_render_native_model_and_effort_and_reject_unsupported
    agy = Hive::AgentProfiles.lookup(:agy)
    resolution = Hive::ModelRouting.resolve(
      models: { "execute" => { "model" => "gemini-4-neon-xhigh", "effort" => "xhigh" } },
      stage: "execute", provider: "agy"
    )

    arguments = agy.routing_arguments(resolution)
    assert_equal [ "--model", "gemini-4-neon-xhigh", "--effort", "xhigh" ],
                 arguments.native_arguments

    sentinel = Hive::ModelRouting.resolve(
      models: { "execute" => { "model" => "default", "effort" => "inherit" } },
      stage: "execute", provider: "agy"
    )
    assert_equal [], agy.routing_arguments(sentinel).native_arguments

    invalid = Hive::ModelRouting.resolve(
      models: { "execute" => { "effort" => "minimal" } },
      stage: "execute", provider: "agy"
    )
    assert_raises(Hive::ConfigError) { agy.routing_arguments(invalid) }
  end

  def test_skill_verifier_searches_workspace_global_and_enabled_plugin_roots
    with_tmp_dir do |home|
      project = File.join(home, "project")
      FileUtils.mkdir_p(project)

      plugin_skill = File.join(
        home, ".gemini", "config", "plugins", "compound-engineering",
        "skills", "ce-plan", "SKILL.md"
      )
      FileUtils.mkdir_p(File.dirname(plugin_skill))
      File.write(File.join(home, ".gemini", "config", "plugins", "compound-engineering", "plugin.json"),
                 JSON.generate("name" => "compound-engineering", "version" => "3.35.3"))
      File.write(plugin_skill, "---\nname: ce-plan\n---\n")

      with_env("HOME" => home) do
        status, message = Hive::AgentProfiles.lookup(:agy)
          .verify_skill("/ce-plan", project_root: project)
        assert_equal :present, status
        assert_equal File.expand_path(plugin_skill), message

        # Disabling the plugin in ~/.gemini/config/config.json hides its skills.
        File.write(
          File.join(home, ".gemini", "config", "config.json"),
          JSON.generate("plugins" => { "compound-engineering" => { "enabled" => false } })
        )
        status, hint = Hive::AgentProfiles.lookup(:agy)
          .verify_skill("/ce-plan", project_root: project)
        assert_equal :missing, status
        assert_includes hint, "hive setup-agents --agent agy"

        # A global skill under ~/.gemini/config/skills/ resolves directly.
        global_skill = File.join(home, ".gemini", "config", "skills", "ce-plan", "SKILL.md")
        FileUtils.mkdir_p(File.dirname(global_skill))
        File.write(global_skill, "---\nname: ce-plan\n---\n")
        status, path = Hive::AgentProfiles.lookup(:agy)
          .verify_skill("/ce-plan", project_root: project)
        assert_equal :present, status
        assert_equal File.expand_path(global_skill), path
      end
    end
  end

  def test_spawn_records_result_message_usage_and_scrubbed_env
    with_tmp_dir do |dir|
      task = make_task(dir)
      log_dir = File.join(dir, "fake-log")
      output = File.join(dir, "findings.json")
      ENV["HIVE_FAKE_AGY_LOG_DIR"] = log_dir
      ENV["HIVE_FAKE_AGY_WRITE_FILE"] = output
      ENV["GEMINI_API_KEY"] = "must-not-reach-child"
      ENV["GOOGLE_API_KEY"] = "must-not-reach-child"
      ENV["GOOGLE_APPLICATION_CREDENTIALS"] = "/tmp/fake-adc.json"

      database = Hive::RuntimeControlPlane::Database.new(path: File.join(dir, "usage.sqlite3")).migrate!
      result = with_replaced_singleton_method(Hive::UsageDb, :database, -> { database }) do
        Hive::Stages::Base.spawn_agent(
          task, prompt: "secret prompt body", max_budget_usd: 1,
          timeout_sec: 10, profile: Hive::AgentProfiles.lookup(:agy),
          expected_output: output, model: "requested-model"
        )
      end

      assert_equal :ok, result[:status], result.inspect
      assert_equal "fake agy final", result[:final_message]
      assert_equal :structured, result[:final_message_source]
      assert_equal "gemini-4-neon-xhigh", result[:model]
      assert_equal result[:model], result.dig(:usage, :model)
      assert_equal "provider_stream_event", result[:execution_identity_source]
      row = database.read do |db|
        db[:token_usage].where(task_slug: task.slug, agent: "agy").first
      end
      assert_equal [ "requested-model", "gemini-4-neon-xhigh", 120, 45, 20, 10 ],
                   row.values_at(:requested_model, :actual_model, :input, :output, :reasoning, :cache_read)
      assert_equal 120, result[:usage][:input]
      assert_equal 45, result[:usage][:output]
      assert_equal 20, result[:usage][:reasoning]
      assert_equal 10, result[:usage][:cache_read]
      assert_equal true, result[:usage][:output_includes_reasoning]

      argv_log = File.read(File.join(log_dir, "fake-agy-argv.log"))
      assert_includes argv_log, "arg=--input-format=text"
      assert_includes argv_log, "env_GEMINI_API_KEY=__unset__"
      assert_includes argv_log, "env_GOOGLE_API_KEY=__unset__"
      assert_includes argv_log, "env_GOOGLE_APPLICATION_CREDENTIALS=__unset__"
      assert_equal "secret prompt body", File.read(File.join(log_dir, "fake-agy-stdin.txt"))

      log = File.read(result.fetch(:log_file))
      refute_includes log, "STREAM-SENSITIVE-DELTA"
      refute_includes log, "fake agy final"
      assert_includes log, "[structured message omitted type=step_update]"
      assert_includes log, "[structured message omitted type=result]"
    ensure
      database&.disconnect
    end
  end

  def test_only_concrete_models_from_the_main_conversation_identify_the_run
    identity = Hive::AgentSupport.for(:agy)::Stream::ModelIdentity.new
    identity.observe("event" => "step_update", "step_update" => { "conversation_id" => "child",
                     "step_type" => "agent_response", "model" => "child-model" })
    identity.observe("event" => "init", "conversation_id" => "main", "init" => { "model" => "default" })
    identity.observe("event" => "result", "result" => { "conversation_id" => "child", "model" => "child-model" })
    assert_nil identity.model

    identity.observe("event" => "init", "conversation_id" => "main",
                     "init" => { "model" => "Gemini 4 Neon (XHigh)" })
    identity.observe("event" => "step_update", "step_update" => { "conversation_id" => "child",
                     "step_type" => "agent_response", "model" => "claude-opus" })
    assert_equal "gemini-4-neon-xhigh", identity.model
    identity.observe("event" => "step_update", "step_update" => { "conversation_id" => "main",
                     "step_type" => "agent_response", "model" => "claude-opus-5-5-high" })
    assert_equal "claude-opus-5-5-high", identity.model
    identity.observe("event" => "result", "result" => { "conversation_id" => "main", "model" => "another-model" })
    assert_nil identity.model
    assert_equal [ nil, nil ], Hive::AgentSupport::Agy.execution_identity(identity.model)
  end

  def test_missing_root_id_does_not_allow_a_child_to_claim_the_run
    identity = Hive::AgentSupport.for(:agy)::Stream::ModelIdentity.new
    identity.observe("event" => "init", "init" => { "model" => "gemini-4-neon-xhigh" })
    identity.observe("event" => "init", "conversation_id" => "child", "init" => { "model" => "claude-opus" })
    identity.observe("event" => "result", "result" => { "conversation_id" => "child", "model" => "claude-opus" })

    assert_nil identity.model
  end

  def test_unattributed_generation_cannot_confirm_the_opening_model
    identity = Hive::AgentSupport.for(:agy)::Stream::ModelIdentity.new
    identity.observe("event" => "init", "conversation_id" => "main", "init" => { "model" => "gemini-4-neon-xhigh" })
    identity.observe("event" => "step_update", "step_update" => { "step_type" => "agent_response", "model" => "claude-opus" })
    identity.observe("event" => "result", "result" => { "conversation_id" => "main", "model" => "gemini-4-neon-xhigh" })

    assert_nil identity.model
  end

  def test_spawn_result_error_event_is_an_error_despite_zero_exit
    with_tmp_dir do |dir|
      task = make_task(dir)
      ENV["HIVE_FAKE_AGY_RESULT"] = "error"
      ENV["HIVE_FAKE_AGY_ERROR"] = "fake provider failure"

      result = Hive::Agent.new(
        task: task, prompt: "x", max_budget_usd: 1, timeout_sec: 10,
        profile: Hive::AgentProfiles.lookup(:agy),
        expected_output: File.join(dir, "findings.json")
      ).run!

      assert_equal :error, result[:status], result.inspect
      assert_includes result[:error_message].to_s, "fake provider failure"
    end
  end

  def test_spawn_result_rate_limit_event_marks_limits_reached
    with_tmp_dir do |dir|
      task = make_task(dir)
      ENV["HIVE_FAKE_AGY_RESULT"] = "error"
      ENV["HIVE_FAKE_AGY_ERROR"] = "429: rate limit exceeded"

      result = Hive::Agent.new(
        task: task, prompt: "x", max_budget_usd: 1, timeout_sec: 10,
        profile: Hive::AgentProfiles.lookup(:agy),
        expected_output: File.join(dir, "findings.json")
      ).run!

      assert_equal :error, result[:status], result.inspect
      assert_equal "limits_reached", result[:error_reason]
      assert_equal :rate_limited, result.dig(:provider_error, :kind)
      assert_includes result[:limit_text].to_s, "rate limit"
    end
  end

  def test_spawn_nonzero_exit_is_an_error
    with_tmp_dir do |dir|
      task = make_task(dir)
      ENV["HIVE_FAKE_AGY_EXIT"] = "3"

      result = Hive::Agent.new(
        task: task, prompt: "x", max_budget_usd: 1, timeout_sec: 10,
        profile: Hive::AgentProfiles.lookup(:agy),
        expected_output: File.join(dir, "never-written.json")
      ).run!

      assert_equal :error, result[:status], result.inspect
      assert_equal 3, result[:exit_code]
    end
  end

  def test_spawn_timeout_kills_the_process_group
    with_tmp_dir do |dir|
      task = make_task(dir)
      ENV["HIVE_FAKE_AGY_HANG"] = "30"

      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      result = Hive::Agent.new(
        task: task, prompt: "x", max_budget_usd: 1, timeout_sec: 1,
        profile: Hive::AgentProfiles.lookup(:agy),
        expected_output: File.join(dir, "never-written.json")
      ).run!
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

      assert_equal :timeout, result[:status], result.inspect
      assert_operator elapsed, :<, 15
    end
  end

  def test_support_helpers_cover_directories_identity_auth_and_raw_line_redaction
    env = {
      "HOME" => "/tmp/agy-home",
      "GEMINI_API_KEY" => "secret",
      "GOOGLE_API_KEY" => "secret",
      "GOOGLE_APPLICATION_CREDENTIALS" => "/tmp/adc.json",
      "PATH" => "/usr/bin"
    }

    assert_equal "/tmp/agy-home/.gemini/antigravity-cli",
                 Hive::AgentSupport::Agy.state_directory(environment: env)
    assert_equal [ "google", "gemini-4-neon-xhigh" ],
                 Hive::AgentSupport::Agy.execution_identity("gemini-4-neon-xhigh")
    assert_equal [ nil, nil ],
                 Hive::AgentSupport::Agy.execution_identity("")
    assert_equal({ permission_mode: nil, allowed_tools: nil, disallowed_tools: nil },
                 Hive::AgentSupport::Agy.plan_review_launch_kwargs(permission_mode: "read-only"))
    assert_equal({ "HOME" => "/tmp/agy-home", "PATH" => "/usr/bin" },
                 Hive::AgentSupport::Agy.auth_environment(env))
    assert_equal "Custom Model!",
                 Hive::AgentSupport::Agy.normalize_settings_model("Custom Model!")
    assert Hive::AgentSupport::Agy.sensitive_payload?(
      nil, raw_line: '{"event":"step_update","text":"truncated'
    )
    assert Hive::AgentSupport::Agy.sensitive_payload?(
      nil, raw_line: '{"event":"result","result":{"status":"SUCCESS","response":"truncated'
    )
    refute Hive::AgentSupport::Agy.sensitive_payload?(
      nil, raw_line: '{"event":"result","result":{"status":"ERROR","error":"boom"}}'
    )
  end
end
