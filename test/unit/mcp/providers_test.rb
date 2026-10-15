require "test_helper"
require "hive/config"
require "hive/agent"
require "hive/agent_profiles"
require "hive/agent_runtime"
require "hive/diagnosis_agent"
require "hive/daily_digest/document_generator"
require "hive/display_name/generator"
require "hive/task"
require "hive/mcp"

# OpenCode, Pi and Grok rendering, the Pi 1.0.4 floor, and the launchers
# that compile and spawn an agent outside Hive::Agent.
class McpProvidersTest < Minitest::Test
  include HiveTestHelper

  CATALOG = {
    "docs" => { "url" => "https://developers.example.com/mcp", "headers" => { "X-Team" => "core" } },
    "internal-api" => {
      "url" => "https://mcp.example.com/mcp", "bearer_token_env" => "INTERNAL_MCP_TOKEN",
      "headers_env" => { "X-Org" => "INTERNAL_ORG" }
    },
    "linear" => { "url" => "https://mcp.linear.app/mcp", "oauth_logins" => [ "codex" ] },
    "context7" => {
      "command" => "npx", "args" => [ "-y", "ctx7" ], "env" => { "LOG_LEVEL" => "warn" },
      "env_from" => { "CONTEXT7_API_KEY" => "HOST_CONTEXT7_KEY" }, "cwd" => "/srv"
    },
    "plain" => { "command" => "marker-server" }
  }.freeze

  def with_catalog
    with_tmp_global_config(runtime: false) do |home|
      File.write(File.join(home, "config.yml"),
                 { "registered_projects" => [], "mcp" => { "servers" => CATALOG } }.to_yaml)
      yield home
    end
  end

  def granted(*names)
    Hive::Mcp::Settings.resolve({ "mcp" => { "use" => names } }, scope: "execute")
  end

  def fake_opencode(dir, body)
    path = File.join(dir, "opencode")
    File.write(path, "#!/bin/sh\n#{body}\n")
    FileUtils.chmod(0o755, path)
    Struct.new(:name, :bin).new(:opencode, path)
  end

  def opencode_prepare(profile, policy = Hive::Mcp::EMPTY_POLICY, cwd: Dir.pwd)
    Hive::Mcp.prepare(profile: profile, policy: policy, cwd: cwd)
  end

  # --- OpenCode -------------------------------------------------------------

  def test_opencode_disables_discovered_servers_and_adds_grants
    with_catalog do
      with_tmp_dir do |dir|
        work = File.join(dir, "work")
        FileUtils.mkdir_p(work)
        profile = fake_opencode(dir, <<~SH)
          [ "$1 $2" = "debug config" ] || exit 9
          [ "$(pwd)" = "#{File.realpath(work)}" ] || exit 8
          printf '{"mcp":{"personal":{"type":"remote","url":"https://p"},"project":{"type":"local","command":["x"]}}}'
        SH
        launch = opencode_prepare(profile, granted("docs", "internal-api", "linear", "context7", "plain"), cwd: work)

        assert_equal :isolated, launch.isolation
        assert_empty launch.arguments
        assert_equal({
          "mcp" => {
            "personal" => { "enabled" => false },
            "project" => { "enabled" => false },
            "docs" => {
              "type" => "remote", "url" => "https://developers.example.com/mcp", "enabled" => true,
              "headers" => { "X-Team" => "core" }
            },
            "internal-api" => {
              "type" => "remote", "url" => "https://mcp.example.com/mcp", "enabled" => true,
              "headers" => { "X-Org" => "{env:INTERNAL_ORG}", "Authorization" => "Bearer {env:INTERNAL_MCP_TOKEN}" }
            },
            "context7" => {
              "type" => "local", "command" => [ "npx", "-y", "ctx7" ], "enabled" => true,
              "environment" => { "LOG_LEVEL" => "warn", "CONTEXT7_API_KEY" => "{env:HOST_CONTEXT7_KEY}" }
            },
            "plain" => { "type" => "local", "command" => [ "marker-server" ], "enabled" => true }
          }
        }, launch.config_overlay)
        assert_equal %w[INTERNAL_MCP_TOKEN INTERNAL_ORG HOST_CONTEXT7_KEY], launch.passthrough_env
        assert_equal [
          "MCP server linear skipped: opencode has no saved login for it; run `hive mcp login linear --agent opencode`",
          "MCP server context7: OpenCode has no per-server cwd; it starts in the agent's cwd"
        ], launch.notices
      end
    end
  end

  def test_opencode_probe_failures_launch_with_a_notice
    with_tmp_dir do |dir|
      {
        "exit 3" => "`opencode debug config` exited 3",
        "printf 'not json'" => "`opencode debug config` returned malformed JSON",
        "printf '[]'" => "`opencode debug config` returned malformed JSON",
        %(printf '{"mcp":[]}') => "`opencode debug config` returned a malformed mcp table"
      }.each do |body, message|
        launch = opencode_prepare(fake_opencode(dir, body))

        assert_equal :partial, launch.isolation, body
        assert_nil launch.config_overlay, body
        assert_equal [ "MCP isolation incomplete: #{message}; OpenCode keeps its own MCP servers" ], launch.notices
      end

      missing = Struct.new(:name, :bin).new(:opencode, File.join(dir, "absent"))
      assert_includes opencode_prepare(missing).notices.first, "could not run (ENOENT)"

      slow = fake_opencode(dir, "sleep 5")
      launch = with_replaced_singleton_method(Hive::AgentSupport::OpenCode::Mcp, :probe_timeout, -> { 0.1 }) do
        opencode_prepare(slow)
      end
      assert_includes launch.notices.first, "timed out after 0.1s"
    end
  end

  def test_opencode_execution_merges_the_overlay_into_its_config_content
    with_tmp_dir do |dir|
      task = make_task(dir)
      launch = Hive::Mcp.launch(isolation: :isolated, config_overlay: { "mcp" => { "personal" => { "enabled" => false } } })
      agent = Hive::Agent.new(
        task: task, prompt: "x", max_budget_usd: nil, timeout_sec: 5,
        profile: Hive::AgentProfiles.lookup(:opencode), mcp_launch: launch
      )
      agent.extend(Hive::AgentSupport::OpenCode::Execution)
      configuration = Hive::AgentSupport::OpenCode::Configuration.new(configuration: { "model" => "a/b" })

      assert_equal(
        { "model" => "a/b", "mcp" => { "personal" => { "enabled" => false } } },
        agent.send(:native_configuration_content, configuration)
      )
    end
  end

  # --- Pi and Grok ------------------------------------------------------------

  def test_pi_disables_mcp_and_drops_grants_with_a_notice
    with_catalog do
      launch = Hive::Mcp.prepare(profile: Hive::AgentProfiles.lookup(:pi), policy: granted("docs", "plain"), cwd: Dir.pwd)

      assert_equal [ "--no-mcp" ], launch.arguments
      assert_equal :isolated, launch.isolation
      assert_equal [ "MCP server(s) docs, plain not rendered: Pi cannot receive Hive-granted servers" ], launch.notices
      assert_empty Hive::Mcp.prepare(profile: Hive::AgentProfiles.lookup(:pi), policy: Hive::Mcp::EMPTY_POLICY, cwd: Dir.pwd).notices
    end
  end

  def test_pi_below_1_0_4_is_refused_at_preflight
    assert_equal "1.0.4", Hive::Config::DEFAULTS.dig("agents", "pi", "min_version")
    with_tmp_dir do |home|
      FileUtils.mkdir_p(File.join(home, ".pi", "agent"))
      File.write(File.join(home, ".pi", "agent", "auth.json"), '{"provider":"configured"}')
      bin = File.join(home, "pi")
      { "1.0.3" => false, "1.0.4" => true }.each do |version, admitted|
        File.write(bin, "#!/bin/sh\nprintf '%s\\n' 'pi #{version}'\n")
        FileUtils.chmod(0o755, bin)
        Hive::AgentProfile.reset_version_cache!
        with_env("HOME" => home, "HIVE_PI_BIN" => bin, "PI_CODING_AGENT_DIR" => nil) do
          profile = Hive::AgentProfiles.lookup(:pi, cfg: Hive::Config::DEFAULTS)
          if admitted
            assert_equal "1.0.4", Hive::AgentRuntime.prepare!(profile).version
          else
            error = assert_raises(Hive::AgentError) { Hive::AgentRuntime.prepare!(profile) }
            assert_includes error.message, "1.0.4"
          end
        end
      end
    end
  ensure
    Hive::AgentProfile.reset_version_cache!
  end

  def test_grok_launches_unchanged_with_a_notice
    launch = Hive::Mcp.prepare(profile: Hive::AgentProfiles.lookup(:grok), policy: Hive::Mcp::EMPTY_POLICY, cwd: Dir.pwd)

    assert_equal :none, launch.isolation
    assert_empty launch.arguments
    assert_equal [ "MCP isolation incomplete: Grok has no flag to ignore its own MCP config" ], launch.notices
  end

  # --- launchers outside Hive::Agent -----------------------------------------

  def make_task(dir, stage = "4-execute")
    folder = File.join(dir, ".hive-state", "stages", stage, "mcp-launcher-261015-aaaa")
    FileUtils.mkdir_p(folder)
    prepare_test_task_run(folder)
    Hive::Task.new(folder)
  end

  def test_diagnosis_launch_renders_the_diagnose_grant_and_cleans_up
    with_catalog do
      with_tmp_dir do |dir|
        task = make_task(dir)
        agent = Hive::DiagnosisAgent.new(task: task)
        agent.instance_variable_set(:@cfg, { "diagnose" => { "mcp" => { "use" => %w[docs] } } })
        seen = nil
        agent.define_singleton_method(:run_with_timeout) do |cmd, _cwd, _stdin, _timeout, environment|
          path = cmd[cmd.index("--mcp-config") + 1]
          seen = { cmd: cmd, path: path, config: JSON.parse(File.read(path)), environment: environment }
          "ok"
        end

        with_env("INTERNAL_MCP_TOKEN" => nil) do
          agent.send(:spawn_profile, profile: Hive::AgentProfiles.lookup(:claude), prompt: "p", cwd: dir,
                                     add_dirs: [], timeout_sec: 5, max_budget_usd: 1)
        end

        assert_includes seen.fetch(:cmd), "--strict-mcp-config"
        assert_equal %w[docs], seen.fetch(:config).fetch("mcpServers").keys
        refute File.exist?(seen.fetch(:path))
      end
    end
  end

  def test_digest_and_display_name_launches_are_isolated
    with_tmp_global_config do
      config = Hive::Config::DEFAULTS.merge("daily_digest" => { "agent" => "claude" })
      generator = Hive::DailyDigest::DocumentGenerator.new(config_loader: -> { config })
      captured = nil
      generator.define_singleton_method(:capture) do |invocation, _profile|
        captured = invocation.argv
        { type: "result", subtype: "success", is_error: false, result: "Digest." }.to_json
      end
      assert_equal "Digest.", generator.generate({})
      assert_includes captured, "--strict-mcp-config"

      launch = Hive::Mcp.launch(isolation: :isolated, passthrough_env: %w[HOST_DIGEST_VAR])
      generator = Hive::DailyDigest::DocumentGenerator.new(config_loader: -> { config })
      generator.instance_variable_set(:@mcp_launch, launch)
      invocation = Struct.new(:argv, :stdin_data).new([ RbConfig.ruby, "-e", "print ENV['HOST_DIGEST_VAR']" ], "")
      with_env("HOST_DIGEST_VAR" => "from-host") do
        assert_equal "from-host", generator.send(:capture, invocation, Struct.new(:subscription_environment).new({}))
      end
    end

    with_tmp_dir do |dir|
      task = make_task(dir, "1-inbox")
      bin = File.join(dir, "fake-display-agent")
      log = File.join(dir, "argv.log")
      File.write(bin, "#!/bin/sh\nprintf '%s\\n' \"$@\" > #{log}\nexit 0\n")
      FileUtils.chmod(0o755, bin)
      cfg = { "execute" => { "agent" => "claude" }, "agents" => { "claude" => { "bin" => bin } } }
      generator = Hive::DisplayName::Generator.new(task, cfg: Hive::Config.deep_merge(Hive::Config::DEFAULTS, cfg))
      generator.send(:run_agent, Hive::Stages::Base.stage_profile(generator.instance_variable_get(:@cfg), "execute"))

      assert_includes File.read(log), "--strict-mcp-config"
    end
  end
end
