require "test_helper"
require "hive/config"
require "hive/agent_profiles"
require "hive/mcp"

class McpLaunchTest < Minitest::Test
  include HiveTestHelper

  CATALOG = {
    "linear" => { "url" => "https://mcp.linear.app/mcp", "oauth_logins" => [ "codex" ] },
    "writero" => {
      "url" => "https://writero.app/mcp", "oauth_resource" => "https://writero.app/mcp",
      "oauth_logins" => %w[claude codex]
    },
    "docs" => { "url" => "https://developers.example.com/mcp" },
    "internal-api" => {
      "url" => "https://mcp.example.com/mcp",
      "headers" => { "X-Team" => "core" },
      "bearer_token_env" => "INTERNAL_MCP_TOKEN",
      "headers_env" => { "X-Org" => "INTERNAL_ORG" }
    },
    "context7" => {
      "command" => "npx",
      "args" => [ "-y", "@upstash/context7-mcp@1.0.14" ],
      "env" => { "LOG_LEVEL" => "warn" },
      "env_from" => { "CONTEXT7_API_KEY" => "HOST_CONTEXT7_KEY" },
      "cwd" => "/srv"
    },
    "plain" => { "command" => "marker-server" }
  }.freeze

  def claude = Hive::AgentProfiles.lookup(:claude)

  def with_catalog(catalog = CATALOG)
    with_tmp_global_config(runtime: false) do |home|
      File.write(File.join(home, "config.yml"),
                 { "registered_projects" => [], "mcp" => { "servers" => catalog } }.to_yaml)
      yield
    end
  end

  def granted(*names)
    Hive::Mcp::Settings.resolve({ "mcp" => { "use" => names } }, scope: "execute")
  end

  def rendered(launch)
    path = launch.arguments.last
    [ JSON.parse(File.read(path)), path ]
  end

  def test_empty_grant_renders_a_strict_empty_private_config
    launch = Hive::Mcp.prepare(profile: claude, policy: Hive::Mcp::EMPTY_POLICY, cwd: Dir.pwd)
    config, path = rendered(launch)

    assert_equal [ "--strict-mcp-config", "--mcp-config", path ], launch.arguments
    assert_equal({ "mcpServers" => {} }, config)
    assert_equal :isolated, launch.isolation
    assert_equal 0o600, File.stat(path).mode & 0o777
    assert_equal 0o700, File.stat(File.dirname(path)).mode & 0o777
    assert_equal [ File.dirname(path) ], launch.cleanup_paths
    assert_predicate launch, :frozen?

    launch.cleanup!
    refute File.exist?(File.dirname(path))
    launch.cleanup!
  end

  def test_claude_entries_repeat_catalog_name_type_url_and_headers
    with_catalog do
      launch = Hive::Mcp.prepare(
        profile: claude, policy: granted("writero", "docs", "internal-api", "context7", "plain"), cwd: Dir.pwd
      )
      config, = rendered(launch)

      assert_equal({
        "writero" => { "type" => "http", "url" => "https://writero.app/mcp" },
        "docs" => { "type" => "http", "url" => "https://developers.example.com/mcp" },
        "internal-api" => {
          "type" => "http", "url" => "https://mcp.example.com/mcp",
          "headers" => {
            "X-Team" => "core", "X-Org" => "${INTERNAL_ORG}",
            "Authorization" => "Bearer ${INTERNAL_MCP_TOKEN}"
          }
        },
        "context7" => {
          "type" => "stdio", "command" => "npx", "args" => [ "-y", "@upstash/context7-mcp@1.0.14" ],
          "env" => { "LOG_LEVEL" => "warn", "CONTEXT7_API_KEY" => "${HOST_CONTEXT7_KEY}" }
        },
        "plain" => { "type" => "stdio", "command" => "marker-server", "args" => [] }
      }, config.fetch("mcpServers"))
      assert_equal %w[INTERNAL_MCP_TOKEN INTERNAL_ORG HOST_CONTEXT7_KEY].sort, launch.passthrough_env.sort
      assert_includes launch.notices.join("\n"), "context7: Claude has no per-server cwd"
    ensure
      launch&.cleanup!
    end
  end

  def test_secret_values_never_reach_argv_or_the_rendered_file
    with_catalog do
      with_env("INTERNAL_MCP_TOKEN" => "sekret-token-value", "HOST_CONTEXT7_KEY" => "sekret-context-key") do
        launch = Hive::Mcp.prepare(profile: claude, policy: granted("internal-api", "context7"), cwd: Dir.pwd)
        text = File.read(launch.arguments.last)

        refute_match(/sekret/, text)
        refute_match(/sekret/, launch.arguments.join(" "))
        assert_empty launch.environment
      ensure
        launch&.cleanup!
      end
    end
  end

  def test_oauth_server_is_skipped_for_an_agent_without_a_saved_login
    with_catalog do
      launch = Hive::Mcp.prepare(profile: claude, policy: granted("linear", "writero"), cwd: Dir.pwd)
      config, = rendered(launch)

      assert_equal %w[writero], config.fetch("mcpServers").keys
      assert_equal [
        "MCP server linear skipped: claude has no saved login for it; " \
        "run `hive mcp login linear --agent claude`"
      ], launch.notices
    ensure
      launch&.cleanup!
    end
  end

  def test_oauth_detection
    with_catalog do
      servers = granted("linear", "writero", "docs", "internal-api", "context7").servers.to_h { [ _1.name, _1 ] }

      assert Hive::Mcp.oauth?(servers.fetch("linear"))
      assert Hive::Mcp.oauth?(servers.fetch("writero"))
      refute Hive::Mcp.oauth?(servers.fetch("docs"))
      refute Hive::Mcp.oauth?(servers.fetch("internal-api"))
      refute Hive::Mcp.oauth?(servers.fetch("context7"))
    end
  end

  def test_inherit_user_adds_nothing
    policy = Hive::Mcp::Settings::Policy.new(inherit_user: true, servers: [], notices: [ "n" ])
    launch = Hive::Mcp.prepare(profile: claude, policy: policy, cwd: Dir.pwd)

    assert_equal :inherit, launch.isolation
    assert_empty launch.arguments
    assert_empty launch.cleanup_paths
    assert_equal [ "n" ], launch.notices
  end

  def test_profile_without_a_renderer_launches_unisolated_with_a_notice
    with_catalog do
      profile = Struct.new(:name).new(:custom)
      launch = Hive::Mcp.prepare(profile: profile, policy: granted("docs"), cwd: Dir.pwd)

      assert_equal :none, launch.isolation
      assert_empty launch.arguments
      assert_equal [
        "MCP isolation incomplete: agent custom has no Hive MCP renderer, so it keeps its own MCP config; " \
        "granted server(s) docs not rendered"
      ], launch.notices

      bare = Hive::Mcp.prepare(profile: :custom, policy: Hive::Mcp::EMPTY_POLICY, cwd: Dir.pwd)
      assert_equal [ "MCP isolation incomplete: agent custom has no Hive MCP renderer, so it keeps its own MCP config" ],
                   bare.notices
    end
  end

  def test_render_failure_removes_the_private_directory
    created = nil
    original = Hive::Mcp.method(:private_dir)
    failing = lambda do
      created = original.call
    end
    with_replaced_singleton_method(Hive::Mcp, :private_dir, failing) do
      with_replaced_singleton_method(Hive::Mcp, :write_private_json, ->(*) { raise IOError, "disk full" }) do
        assert_raises(IOError) do
          Hive::Mcp.prepare(profile: claude, policy: Hive::Mcp::EMPTY_POLICY, cwd: Dir.pwd)
        end
      end
    end
    refute File.exist?(created)
  end

  def test_policy_and_scope_helpers
    assert_same Hive::Mcp::EMPTY_POLICY, Hive::Mcp.policy(nil, scope: "execute")
    with_catalog do
      assert_equal %w[docs], Hive::Mcp.policy({ "mcp" => { "use" => %w[docs] } }, scope: "plan").servers.map(&:name)
    end
    assert_equal "execute", Hive::Mcp.scope_for("4-execute")
    assert_equal "open_pr", Hive::Mcp.scope_for("5-open-pr")
    assert_equal "design", Hive::Mcp.scope_for("design")
  end

  def test_with_launch_cleans_up_after_the_block_even_when_it_raises
    seen = nil
    assert_raises(RuntimeError) do
      Hive::Mcp.with_launch(profile: claude, cfg: nil, scope: "patrol", cwd: Dir.pwd) do |launch|
        seen = launch
        raise "boom"
      end
    end
    assert_equal :isolated, seen.isolation
    refute File.exist?(seen.cleanup_paths.first)
  end
end
