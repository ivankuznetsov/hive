require "test_helper"
require "hive/config"
require "hive/agent"
require "hive/agent_profiles"
require "hive/task"
require "hive/reviewers"
require "hive/mcp"

class McpCodexTest < Minitest::Test
  include HiveTestHelper

  USER_CONFIG = <<~TOML.freeze
    # personal settings
    model = "gpt-5.6-terra"
    model_reasoning_effort = "high" # trailing comment
    service_tier = "flex"
    personality = 'pragmatic'
    model_provider = "corp"
    profile = "work"
    openai_base_url = "https://api.example.com/v1"
    mcp_oauth_credentials_store = "file"
    approvals_reviewer = "user"
    notify = [
      "say", "done"
    ]

    [model_providers.corp]
    name = "Corp"
    base_url = "https://llm.example.com/v1"
    env_key = "CORP_API_KEY"
    http_headers = { "X-Key" = "literal" }

    [model_providers.corp.query_params]
    api-version = "2026-01-01"

    [profiles.work]
    model = "gpt-5.6-sol"
    instructions = """
    multi
    """

    [mcp_servers.linear]
    url = "https://mcp.linear.app/mcp"

    [plugins."compound-engineering@compound-engineering-plugin"]
    enabled = true

    [plugins."llm-wiki@aikuznetsov-marketplace"]
    enabled = false

    [projects."/home/me/Dev/x"]
    trust_level = "trusted"

    [[skills.entries]]
    name = "x"
  TOML

  CATALOG = {
    "linear" => { "url" => "https://mcp.linear.app/mcp", "oauth_logins" => [ "codex" ] },
    "screenote" => { "url" => "https://screenote.example/mcp", "oauth_logins" => [ "claude" ] },
    "writero" => { "url" => "https://writero.app/mcp", "oauth_resource" => "https://writero.app/mcp", "oauth_logins" => %w[codex] },
    "internal-api" => {
      "url" => "https://mcp.example.com/mcp", "headers" => { "X-Team" => "core" },
      "bearer_token_env" => "INTERNAL_MCP_TOKEN", "headers_env" => { "X-Org" => "INTERNAL_ORG" }
    },
    "context7" => {
      "command" => "npx", "args" => [ "-y", "@upstash/context7-mcp@1.0.14" ],
      "env" => { "LOG_LEVEL" => "warn" }, "cwd" => "/srv",
      "env_from" => { "CONTEXT7_API_KEY" => "HOST_CONTEXT7_KEY", "SHARED" => "SHARED" }
    }
  }.freeze

  def codex = Hive::AgentProfiles.lookup(:codex)
  def user_config_class = Hive::AgentSupport.for(:codex)::UserConfig

  def with_codex_home(content = USER_CONFIG)
    with_tmp_dir do |dir|
      File.write(File.join(dir, "config.toml"), content) if content
      with_env("CODEX_HOME" => dir) { yield dir }
    end
  end

  def with_catalog
    with_tmp_global_config(runtime: false) do |home|
      File.write(File.join(home, "config.yml"),
                 { "registered_projects" => [], "mcp" => { "servers" => CATALOG } }.to_yaml)
      yield
    end
  end

  def granted(*names)
    Hive::Mcp::Settings.resolve({ "mcp" => { "use" => names } }, scope: "execute")
  end

  def prepare(policy = Hive::Mcp::EMPTY_POLICY)
    Hive::Mcp.prepare(profile: codex, policy: policy, cwd: Dir.pwd)
  end

  def make_task(dir)
    folder = File.join(dir, ".hive-state", "stages", "4-execute", "codex-mcp-261015-aaaa")
    FileUtils.mkdir_p(folder)
    prepare_test_task_run(folder)
    Hive::Task.new(folder)
  end

  # --- config.toml reader ---------------------------------------------------

  def test_user_config_reads_single_line_values_and_tables
    document = user_config_class.parse(USER_CONFIG)

    assert_equal '"gpt-5.6-terra"', document["model"]
    assert_equal '"high"', document["model_reasoning_effort"]
    assert_equal "'pragmatic'", document["personality"]
    assert_equal "true", document.table("plugins", "compound-engineering@compound-engineering-plugin")["enabled"]
    assert_equal({ "trust_level" => '"trusted"' }, document.table("projects", "/home/me/Dev/x"))
    assert_equal [ %w[model_providers corp], %w[model_providers corp query_params] ],
                 document.tables_under("model_providers").keys
    assert_equal({}, document.table("absent"))
    assert_equal %w[notify profiles.work.instructions], document.skipped
    refute document.sections.key?(%w[skills entries])
    assert_equal "gpt-5.6-terra", user_config_class.string(document["model"])
    assert_equal "pragmatic", user_config_class.string(document["personality"])
    assert_nil user_config_class.string("true")
    assert_nil user_config_class.string(nil)
  end

  def test_user_config_location_and_missing_file
    with_env("CODEX_HOME" => "/srv/codex") do
      assert_equal "/srv/codex/config.toml", user_config_class.path
    end
    with_env("CODEX_HOME" => nil) do
      assert_equal File.join(Dir.home, ".codex", "config.toml"), user_config_class.path
    end
    assert_same user_config_class::EMPTY, user_config_class.load("/nonexistent/config.toml")
    assert_equal [ "x.y" ], user_config_class.parse("[x]\n[x.\"bad\n[x]\ny = [\n").skipped
  end

  # --- launch rendering -------------------------------------------------------

  def test_empty_grant_without_config_ignores_user_config_only
    with_codex_home(nil) do
      launch = prepare

      assert_equal [ "--ignore-user-config" ], launch.arguments
      assert_empty launch.default_arguments
      assert_equal :isolated, launch.isolation
      assert_empty launch.cleanup_paths
      assert_empty launch.notices
    end
  end

  def test_carries_model_effort_od_a_settings_and_enabled_managed_plugins
    with_codex_home do
      launch = prepare

      assert_equal [
        "--ignore-user-config",
        "-c", "plugins.compound-engineering@compound-engineering-plugin.enabled=true"
      ], launch.arguments
      assert_equal [
        [ "--model", "gpt-5.6-terra" ],
        [ "-c", 'model_reasoning_effort="high"' ],
        [ "-c", 'service_tier="flex"' ],
        [ "-c", "personality='pragmatic'" ],
        [ "-c", 'model_provider="corp"' ],
        [ "-c", 'profile="work"' ],
        [ "-c", 'openai_base_url="https://api.example.com/v1"' ],
        [ "-c", 'mcp_oauth_credentials_store="file"' ],
        [ "-c", 'model_providers.corp.name="Corp"' ],
        [ "-c", 'model_providers.corp.base_url="https://llm.example.com/v1"' ],
        [ "-c", 'model_providers.corp.env_key="CORP_API_KEY"' ],
        [ "-c", 'model_providers.corp.query_params.api-version="2026-01-01"' ],
        [ "-c", 'profiles.work.model="gpt-5.6-sol"' ]
      ], launch.default_arguments
      refute_match(/literal|approvals_reviewer|notify|linear|trust_level/, launch.default_arguments.flatten.join(" "))
      assert_equal [
        "Codex setting model_providers.corp.http_headers not carried over: it may hold a credential; " \
        "export it through the provider's env_key instead",
        "Codex setting profiles.work.instructions not carried over: Hive reads only single-line config.toml values"
      ], launch.notices
    end
  end

  def test_carried_settings_yield_to_the_launch_identity
    with_codex_home do
      launch = prepare
      argv = launch.arguments_for([ "--model", "gpt-5.6-sol", "-c", "model_reasoning_effort=low" ])

      refute_includes argv, "gpt-5.6-terra"
      refute_includes argv, 'model_reasoning_effort="high"'
      assert_includes argv, 'service_tier="flex"'
      assert_equal launch.arguments + launch.default_arguments.flatten, launch.arguments_for([])
    end
  end

  def test_granted_servers_render_as_overrides_with_env_names_only
    with_codex_home(nil) do
      with_catalog do
        with_env("HOST_CONTEXT7_KEY" => "sekret-context", "INTERNAL_MCP_TOKEN" => "sekret-token") do
          launch = prepare(granted("linear", "screenote", "writero", "internal-api", "context7"))

          assert_equal [
            "--ignore-user-config",
            "-c", 'mcp_servers.linear.url="https://mcp.linear.app/mcp"',
            "-c", 'mcp_servers.writero.url="https://writero.app/mcp"',
            "-c", 'mcp_servers.writero.oauth_resource="https://writero.app/mcp"',
            "-c", 'mcp_servers.internal-api.url="https://mcp.example.com/mcp"',
            "-c", 'mcp_servers.internal-api.bearer_token_env_var="INTERNAL_MCP_TOKEN"',
            "-c", 'mcp_servers.internal-api.http_headers={ X-Team = "core" }',
            "-c", 'mcp_servers.internal-api.env_http_headers={ X-Org = "INTERNAL_ORG" }',
            "-c", 'mcp_servers.context7.command="npx"',
            "-c", 'mcp_servers.context7.args=["-y","@upstash/context7-mcp@1.0.14"]',
            "-c", 'mcp_servers.context7.env={ LOG_LEVEL = "warn" }',
            "-c", 'mcp_servers.context7.env_vars=["CONTEXT7_API_KEY","SHARED"]',
            "-c", 'mcp_servers.context7.cwd="/srv"'
          ], launch.arguments
          assert_equal({ "CONTEXT7_API_KEY" => "sekret-context" }, launch.environment)
          assert_equal %w[INTERNAL_MCP_TOKEN INTERNAL_ORG HOST_CONTEXT7_KEY SHARED], launch.passthrough_env
          refute_match(/sekret/, launch.arguments.join(" "))
          assert_equal [
            "MCP server screenote skipped: codex has no saved login for it; " \
            "run `hive mcp login screenote --agent codex`"
          ], launch.notices
        end
        with_env("HOST_CONTEXT7_KEY" => nil) do
          assert_empty prepare(granted("context7")).environment
        end
      end
    end
  end

  def test_toml_keys_that_are_not_bare_are_quoted
    with_codex_home(%([model_providers."corp.eu"]\nname = "EU"\n)) do
      assert_equal [ [ "-c", 'model_providers."corp.eu".name="EU"' ] ], prepare.default_arguments
    end
  end

  # --- argv through Hive::Agent ---------------------------------------------

  def test_agent_argv_has_one_ignore_user_config_for_every_permission_mode
    with_codex_home do
      with_tmp_dir do |dir|
        task = make_task(dir)
        [ nil, "workspace-write", "read-only" ].each do |mode|
          agent = Hive::Agent.new(
            task: task, prompt: "x", max_budget_usd: nil, timeout_sec: 5,
            profile: codex, permission_mode: mode
          )
          cmd = agent.send(:build_cmd)

          assert_equal 1, cmd.count("--ignore-user-config"), mode.inspect
          assert_equal "gpt-5.6-terra", cmd[cmd.index("--model") + 1], mode.inspect
          assert_includes cmd, 'model_reasoning_effort="high"'
          assert_equal "-", cmd.last
        end
      end
    end
  end

  def test_routed_launch_keeps_its_own_model_and_effort
    with_codex_home do
      with_tmp_dir do |dir|
        resolution = Hive::ModelRouting.resolve(
          models: { "review_fix" => { "model" => "routed-model", "effort" => "xhigh" } },
          stage: "review_fix", current: {}, provider: :codex
        )
        agent = Hive::Agent.new(
          task: make_task(dir), prompt: "x", max_budget_usd: nil, timeout_sec: 5,
          profile: codex, routing_arguments: codex.routing_arguments(resolution)
        )
        cmd = agent.send(:build_cmd)

        assert_equal [ "--model", "routed-model", "-c", "model_reasoning_effort=xhigh", "exec" ], cmd[1, 5]
        assert_equal 1, cmd.count("--model")
        assert_equal 1, cmd.count { |argument| argument.start_with?("model_reasoning_effort=") }
        assert_includes cmd, 'service_tier="flex"'
      end
    end
  end

  def test_collapse_repeated_flags_keeps_a_single_flag_invocation
    invocation = Hive::AgentRuntime::CompiledInvocation.new(
      argv: %w[codex exec --ignore-user-config -], stdin_data: nil, provider: :codex,
      launcher_identity: "codex-cli/v1", capability_evidence: []
    )
    assert_same invocation, Hive::Mcp.collapse_repeated_flags(invocation)
  end

  def test_managed_actor_isolation_has_no_dead_mcp_servers_entry
    refute_includes Hive::AgentSupport.for(:codex)::Runtime::ISOLATION_ARGUMENTS, "mcp_servers={}"
  end

  # --- native reviewer ------------------------------------------------------

  def test_native_codex_review_logs_that_it_is_not_isolated
    fake = File.expand_path("../../fixtures/fake-codex", __dir__)
    with_tmp_dir do |dir|
      with_env("HIVE_CODEX_BIN" => fake, "HIVE_FAKE_CODEX_ARGV_LOG" => File.join(dir, "argv.log")) do
        Hive::AgentProfile.reset_version_cache!
        ctx = Hive::Reviewers::Context.new(
          worktree_path: dir, task_folder: File.join(dir, ".hive-state", "stages", "6-review", "t"),
          default_branch: "main", pass: 1
        )
        FileUtils.mkdir_p(ctx.task_folder)
        spec = {
          "name" => "codex-native-review", "kind" => "codex_review", "agent" => "codex",
          "output_basename" => "codex-native-review", "timeout_sec" => 5,
          "prompt_template" => "reviewer_codex_native_review.md.erb"
        }
        result = Hive::AgentSupport.for(:codex)::Reviewer.new(spec, ctx).run!
        assert result.ok?, result.error_message
        warnings = File.join(ctx.task_folder, "logs", "isolation-warnings.log")
        assert_includes File.read(warnings), "`codex review` cannot ignore the operator's Codex config"

        FileUtils.rm_f(warnings)
        Hive::AgentSupport.for(:codex)::Reviewer.new(spec, ctx, cfg: { "mcp" => { "inherit_user" => true } }).run!
        refute File.exist?(warnings)
      end
    end
  ensure
    Hive::AgentProfile.reset_version_cache!
  end
end
