require "test_helper"
require "hive/config"
require "hive/mcp/settings"

class McpSettingsTest < Minitest::Test
  include HiveTestHelper

  CATALOG = {
    "linear" => { "url" => "https://mcp.linear.app/mcp", "imported_from" => "codex" },
    "writero" => { "url" => "https://writero.app/mcp", "oauth_resource" => "https://writero.app/mcp" },
    "context7" => {
      "command" => "npx",
      "args" => [ "-y", "@upstash/context7-mcp@1.0.14" ],
      "env_from" => { "CONTEXT7_API_KEY" => "CONTEXT7_API_KEY" }
    },
    "internal-api" => {
      "url" => "https://mcp.example.com/mcp",
      "bearer_token_env" => "INTERNAL_MCP_TOKEN",
      "headers_env" => { "X-Org" => "INTERNAL_ORG" }
    }
  }.freeze

  def with_project(project, global: { "servers" => CATALOG })
    with_tmp_global_config(runtime: false) do |home|
      unless global.nil?
        File.write(File.join(home, "config.yml"),
                   { "registered_projects" => [], "mcp" => global }.to_yaml)
      end
      with_tmp_dir do |dir|
        FileUtils.mkdir_p(File.join(dir, ".hive-state"))
        File.write(File.join(dir, ".hive-state", "config.yml"), project.to_yaml)
        yield Hive::Config.load(dir), home
      end
    end
  end

  def resolve(cfg, scope)
    Hive::Mcp::Settings.resolve(cfg, scope: scope)
  end

  def test_default_policy_grants_nothing_and_isolates
    with_project({}) do |cfg|
      policy = resolve(cfg, :execute)

      assert_equal false, policy.inherit_user
      assert_equal [], policy.servers
      assert_equal [], policy.notices
      assert_predicate policy.servers, :frozen?
      assert_predicate policy.notices, :frozen?
    end
  end

  def test_project_use_applies_and_a_stage_block_replaces_it
    project = { "mcp" => { "use" => %w[context7] }, "execute" => { "mcp" => { "use" => %w[context7 linear] } } }
    with_project(project) do |cfg|
      assert_equal %w[context7], resolve(cfg, "plan").servers.map(&:name)
      assert_equal %w[context7 linear], resolve(cfg, "execute").servers.map(&:name)
    end
  end

  def test_an_empty_stage_grant_removes_the_project_default
    with_project({ "mcp" => { "use" => %w[context7] }, "plan" => { "mcp" => { "use" => [] } } }) do |cfg|
      assert_equal [], resolve(cfg, "plan").servers
    end
  end

  def test_dotted_scopes_fall_back_to_their_parent_block_then_the_project
    project = {
      "mcp" => { "use" => %w[context7] },
      "review" => { "mcp" => { "use" => %w[linear] }, "fix" => { "mcp" => { "use" => %w[writero] } } }
    }
    with_project(project) do |cfg|
      assert_equal %w[writero], resolve(cfg, "review.fix").servers.map(&:name)
      assert_equal %w[linear], resolve(cfg, "review.triage").servers.map(&:name)
      assert_equal %w[linear], resolve(cfg, "review.reviewers").servers.map(&:name)
    end
  end

  def test_background_roles_ignore_the_project_grant
    with_project({ "mcp" => { "use" => %w[context7 linear] } }) do |cfg|
      %w[babysitter patrol patrol.fix refactor_patrol daily_digest].each do |scope|
        assert_equal [], resolve(cfg, scope).servers, scope
      end
      assert_equal %w[context7 linear], resolve(cfg, "plan_review").servers.map(&:name)
    end
  end

  def test_background_roles_use_their_own_grant
    project = {
      "mcp" => { "use" => %w[context7] },
      "babysitter" => { "mcp" => { "use" => %w[linear] } },
      "patrol" => { "mcp" => { "use" => %w[writero] } }
    }
    with_project(project) do |cfg|
      assert_equal %w[linear], resolve(cfg, "babysitter").servers.map(&:name)
      assert_equal %w[writero], resolve(cfg, "patrol.fix").servers.map(&:name)
    end
  end

  def test_plan_review_and_workflow_stage_blocks_carry_grants
    project = { "plan_review" => { "mcp" => { "use" => %w[linear] } }, "inbox" => { "mcp" => { "use" => %w[writero] } } }
    with_project(project) do |cfg|
      assert_equal %w[linear], resolve(cfg, "plan_review").servers.map(&:name)
      assert_equal %w[writero], resolve(cfg, "inbox").servers.map(&:name)
    end
  end

  def test_servers_carry_every_catalog_field_frozen
    with_project({ "mcp" => { "use" => %w[context7 internal-api writero linear context7] } }) do |cfg|
      servers = resolve(cfg, "execute").servers.to_h { |server| [ server.name, server ] }

      assert_equal %w[context7 internal-api writero linear], servers.keys
      stdio = servers.fetch("context7")
      assert_equal :stdio, stdio.transport
      assert_equal "npx", stdio.command
      assert_equal [ "-y", "@upstash/context7-mcp@1.0.14" ], stdio.args
      assert_equal({ "CONTEXT7_API_KEY" => "CONTEXT7_API_KEY" }, stdio.env_from)
      assert_equal({}, stdio.env)
      assert_nil stdio.url
      assert_predicate stdio.args, :frozen?

      http = servers.fetch("internal-api")
      assert_equal :http, http.transport
      assert_equal "https://mcp.example.com/mcp", http.url
      assert_equal "INTERNAL_MCP_TOKEN", http.bearer_token_env
      assert_equal({ "X-Org" => "INTERNAL_ORG" }, http.headers_env)
      assert_equal({}, http.headers)
      assert_equal [], http.oauth_scopes
      assert_nil http.command
      assert_predicate http.headers_env, :frozen?

      assert_equal "https://writero.app/mcp", servers.fetch("writero").oauth_resource
      assert_equal "codex", servers.fetch("linear").imported_from
    end
  end

  def test_disabled_catalog_servers_are_skipped_with_a_notice
    catalog = CATALOG.merge("linear" => CATALOG.fetch("linear").merge("enabled" => false))
    with_project({ "mcp" => { "use" => %w[linear context7] } }, global: { "servers" => catalog }) do |cfg|
      policy = resolve(cfg, "execute")

      assert_equal %w[context7], policy.servers.map(&:name)
      assert_equal 1, policy.notices.length
      assert_includes policy.notices.first, "MCP server linear granted to execute is disabled"
    end
  end

  def test_unknown_grant_fails_project_load_naming_the_file
    with_tmp_global_config(runtime: false) do
      with_tmp_dir do |dir|
        path = File.join(dir, ".hive-state", "config.yml")
        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, { "execute" => { "mcp" => { "use" => %w[linear] } } }.to_yaml)

        error = assert_raises(Hive::ConfigError) { Hive::Config.load(dir) }

        assert_includes error.message, path
        assert_includes error.message, "missing from the global MCP catalog"
        assert_includes error.message, "linear"
        assert_includes error.message, "hive mcp import"
      end
    end
  end

  def test_unknown_grant_at_resolution_raises_when_the_catalog_lost_it
    with_project({ "mcp" => { "use" => %w[linear] } }) do |cfg, home|
      File.write(File.join(home, "config.yml"), { "registered_projects" => [] }.to_yaml)

      error = assert_raises(Hive::ConfigError) { resolve(cfg, "execute") }

      assert_includes error.message, "MCP grants for execute name server(s) missing"
    end
  end

  def test_unreadable_global_config_skips_grants_with_a_notice
    with_project({ "mcp" => { "use" => %w[linear] } }) do |cfg, home|
      path = File.join(home, "config.yml")
      policy, babysitter = with_replaced_singleton_method(Hive::Config, :global_mcp_catalog_readable?, -> { false }) do
        [ resolve(cfg, "execute"), resolve(cfg, "babysitter") ]
      end

      assert_equal [], policy.servers
      assert_equal false, policy.inherit_user
      assert_equal 1, policy.notices.length
      assert_includes policy.notices.first, "MCP isolation incomplete: global config #{path} is not readable"
      assert_equal [], babysitter.notices
    end
  end

  def test_unreadable_global_config_detection
    with_tmp_global_config(runtime: false) do |home|
      path = File.join(home, "config.yml")
      assert Hive::Config.global_mcp_catalog_readable?
      File.delete(path)
      assert Hive::Config.global_mcp_catalog_readable?
      File.write(path, "{}\n")
      File.chmod(0o000, path)
      expected = Process.uid.zero?
      assert_equal expected, Hive::Config.global_mcp_catalog_readable?
    ensure
      File.chmod(0o600, path) if path && File.exist?(path)
    end
  end

  def test_inherit_user_precedence
    with_project({}, global: { "inherit_user" => true, "servers" => CATALOG }) do |cfg|
      policy = resolve(cfg, "execute")
      assert_equal true, policy.inherit_user
      assert_equal [], policy.servers
    end
    with_project({ "mcp" => { "inherit_user" => false, "use" => %w[linear] } },
                 global: { "inherit_user" => true, "servers" => CATALOG }) do |cfg|
      policy = resolve(cfg, "execute")
      assert_equal false, policy.inherit_user
      assert_equal %w[linear], policy.servers.map(&:name)
    end
    with_project({ "mcp" => { "inherit_user" => true, "use" => %w[linear] } }) do |cfg|
      policy = resolve(cfg, "execute")
      assert_equal true, policy.inherit_user
      assert_equal [], policy.servers
    end
  end

  def test_project_inherit_user_wins_even_when_the_catalog_is_unreadable
    with_project({ "mcp" => { "inherit_user" => true } }) do |cfg|
      policy = with_replaced_singleton_method(Hive::Config, :global_mcp_catalog_readable?, -> { false }) do
        resolve(cfg, "execute")
      end

      assert_equal true, policy.inherit_user
    end
  end

  def test_synthetic_configs_without_provenance_read_the_merged_value
    with_tmp_global_config(runtime: false) do |home|
      File.write(File.join(home, "config.yml"), { "mcp" => { "inherit_user" => true } }.to_yaml)
      cfg = Hive::Config.merge_defaults({})

      assert_equal false, resolve(cfg, "execute").inherit_user
    end
  end
end
