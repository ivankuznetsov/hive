require "test_helper"
require "json"
require "hive/config"
require "hive/task"
require "hive/agent"
require "hive/agent_profiles"
require "hive/stages/base"
require "hive/workflow_package/runtime_policy"

# Hive-owned MCP reaches every Hive::Agent launch: spawn_agent renders the
# scope's grant and removes it afterwards, a bare Agent renders the empty
# grant itself, and a managed policy that already isolates MCP adds nothing.
class McpAgentWiringTest < Minitest::Test
  include HiveTestHelper

  FAKE_BIN = File.expand_path("../../fixtures/fake-claude", __dir__)
  CATALOG = {
    "docs" => { "url" => "https://developers.example.com/mcp" },
    "context7" => { "command" => "npx", "env_from" => { "CONTEXT7_API_KEY" => "HOST_CONTEXT7_KEY" } }
  }.freeze

  def setup
    @prev_bin = ENV["HIVE_CLAUDE_BIN"]
    ENV["HIVE_CLAUDE_BIN"] = FAKE_BIN
    Hive::AgentProfile.reset_version_cache!
  end

  def teardown
    ENV["HIVE_CLAUDE_BIN"] = @prev_bin
    %w[HIVE_FAKE_CLAUDE_LOG_DIR HIVE_FAKE_CLAUDE_WRITE_FILE HIVE_FAKE_CLAUDE_WRITE_CONTENT].each { |key| ENV.delete(key) }
    Hive::AgentProfile.reset_version_cache!
  end

  def make_task(dir, stage = "4-execute")
    folder = File.join(dir, ".hive-state", "stages", stage, "mcp-test-261015-aaaa")
    FileUtils.mkdir_p(folder)
    prepare_test_task_run(folder)
    Hive::Task.new(folder)
  end

  def with_catalog
    with_tmp_global_config(runtime: false) do |home|
      File.write(File.join(home, "config.yml"),
                 { "registered_projects" => [], "mcp" => { "servers" => CATALOG } }.to_yaml)
      with_tmp_dir { |dir| yield dir }
    end
  end

  # Replace Hive::Agent.new with a recorder whose run! reads the rendered
  # MCP file while it still exists.
  def capture_agent_launch(raise_with: nil)
    seen = {}
    fake = Struct.new(:seen, :raise_with) do
      def run!
        raise raise_with if raise_with

        launch = seen[:mcp_launch]
        seen[:config] = JSON.parse(File.read(launch.arguments.last)) if launch&.arguments&.any?
        { status: :ok }
      end
    end
    constructor = lambda do |**kwargs|
      seen.merge!(kwargs)
      fake.new(seen, raise_with)
    end
    with_replaced_singleton_method(Hive::Agent, :new, constructor) { yield seen }
  end

  def spawn(task, **kwargs)
    Hive::Stages::Base.spawn_agent(task, prompt: "x", max_budget_usd: 1, timeout_sec: 5, **kwargs)
  end

  def test_stage_grant_is_rendered_from_the_task_stage_and_removed_after_the_launch
    with_catalog do |dir|
      task = make_task(dir)
      cfg = { "mcp" => { "use" => [] }, "execute" => { "mcp" => { "use" => %w[docs] } } }
      capture_agent_launch do |seen|
        spawn(task, cfg: cfg)

        assert_equal %w[docs], seen.fetch(:config).fetch("mcpServers").keys
        refute File.exist?(seen.fetch(:mcp_launch).cleanup_paths.first)
      end
    end
  end

  def test_explicit_scope_wins_over_the_task_stage
    with_catalog do |dir|
      task = make_task(dir, "6-review")
      cfg = { "babysitter" => { "mcp" => { "use" => %w[context7] } }, "mcp" => { "use" => %w[docs] } }
      capture_agent_launch do |seen|
        spawn(task, cfg: cfg, mcp_scope: "babysitter")
        assert_equal %w[context7], seen.fetch(:config).fetch("mcpServers").keys
      end
      capture_agent_launch do |seen|
        spawn(task, cfg: cfg)
        assert_equal %w[docs], seen.fetch(:config).fetch("mcpServers").keys
      end
    end
  end

  def test_rendered_files_are_removed_when_the_launch_raises
    with_catalog do |dir|
      task = make_task(dir)
      capture_agent_launch(raise_with: RuntimeError.new("boom")) do |seen|
        assert_raises(RuntimeError) { spawn(task, cfg: { "mcp" => { "use" => %w[docs] } }) }
        refute File.exist?(seen.fetch(:mcp_launch).cleanup_paths.first)
      end
    end
  end

  def test_preflight_failure_renders_nothing
    with_catalog do |dir|
      task = make_task(dir)
      prepared = false
      with_replaced_singleton_method(Hive::AgentRuntime, :prepare!, ->(*, **) { raise Hive::AgentError, "too old" }) do
        with_replaced_singleton_method(Hive::Mcp, :prepare, ->(**) { prepared = true }) do
          result = spawn(task, cfg: {})
          assert result.fetch(:preflight_failed)
        end
      end
      refute prepared
    end
  end

  def test_managed_policy_that_isolates_mcp_gets_no_hive_rendering
    with_catalog do |dir|
      task = make_task(dir)
      policy = Hive::WorkflowPackage::RuntimePolicy.compile(
        { "tools" => %w[Read], "directories" => [], "commands" => [], "domains" => [], "credentials" => [] },
        task_folder: task.folder, profile: Hive::AgentProfiles.lookup(:claude),
        policy_dir: File.join(dir, "policy")
      )
      assert policy.mcp_isolated
      capture_agent_launch do |seen|
        spawn(task, cfg: { "mcp" => { "use" => %w[docs] } }, runtime_policy: policy, cleanup_runtime_policy: false)
        assert_nil seen.fetch(:mcp_launch)
      end

      agent = Hive::Agent.new(task: task, prompt: "x", max_budget_usd: 1, timeout_sec: 5, runtime_policy: policy)
      cmd = agent.send(:build_cmd)
      assert_nil agent.mcp_launch
      assert_equal 1, cmd.count("--mcp-config")
      assert_equal policy.mcp_config_path, cmd[cmd.index("--mcp-config") + 1]
    end
  end

  def test_yolo_direct_policy_is_not_isolated_and_gets_hive_flags
    with_tmp_dir do |dir|
      task = make_task(dir)
      scope = Struct.new(:permission_mode, :allowed_tools, :disallowed_tools).new(nil, nil, nil)
      policy = Hive::WorkflowPackage::RuntimePolicy.direct_policy(
        scope, task_root: task.folder, directories: [ task.folder ], environment: {}
      )
      refute policy.mcp_isolated
      agent = Hive::Agent.new(task: task, prompt: "x", max_budget_usd: 1, timeout_sec: 5, runtime_policy: policy)
      cmd = agent.send(:build_cmd)

      assert_includes cmd, "--strict-mcp-config"
      assert_equal agent.mcp_launch.arguments.last, cmd[cmd.index("--mcp-config") + 1]
    ensure
      agent&.cleanup_mcp_launch!
    end
  end

  def test_bare_agent_renders_the_empty_grant_logs_it_and_removes_it_after_run
    with_tmp_dir do |dir|
      task = make_task(dir)
      File.write(task.state_file, "<!-- WAITING -->\n")
      ENV["HIVE_FAKE_CLAUDE_LOG_DIR"] = dir
      agent = Hive::Agent.new(task: task, prompt: "x", max_budget_usd: 1, timeout_sec: 10)
      path = agent.mcp_launch.arguments.last
      assert_equal({ "mcpServers" => {} }, JSON.parse(File.read(path)))

      agent.run!

      refute File.exist?(File.dirname(path))
      argv = File.read(File.join(dir, "fake-claude-argv.log"))
      assert_includes argv, "arg=--strict-mcp-config"
      log = File.read(Dir[File.join(task.log_dir, "*.log")].first)
      assert_includes log, "[hive] mcp isolation=isolated"
    end
  end

  def test_caller_launch_notices_reach_the_log_and_passthrough_env_survives_isolation
    with_tmp_dir do |dir|
      task = make_task(dir)
      File.write(task.state_file, "<!-- WAITING -->\n")
      ENV["HIVE_FAKE_CLAUDE_LOG_DIR"] = dir
      launch = Hive::Mcp.launch(
        isolation: :partial, arguments: [], environment: { "HIVE_MCP_MARKER" => "1" },
        passthrough_env: %w[HOST_CONTEXT7_KEY HIVE_MCP_UNSET_VAR], notices: [ "discovery failed" ]
      )
      with_env("HOST_CONTEXT7_KEY" => "value-from-host", "HIVE_MCP_UNSET_VAR" => nil) do
        agent = Hive::Agent.new(
          task: task, prompt: "x", max_budget_usd: 1, timeout_sec: 10,
          isolate_environment: true, mcp_launch: launch
        )
        environment = agent.child_environment

        assert_equal "value-from-host", environment.fetch("HOST_CONTEXT7_KEY")
        assert_equal "1", environment.fetch("HIVE_MCP_MARKER")
        refute environment.key?("HIVE_MCP_UNSET_VAR")
        assert_same launch, agent.mcp_launch

        agent.run!
        agent.cleanup_mcp_launch!
      end
      log = File.read(Dir[File.join(task.log_dir, "*.log")].first)
      assert_includes log, "[hive] mcp isolation=partial"
      assert_includes log, "[hive] mcp notice: discovery failed"
    end
  end
end
