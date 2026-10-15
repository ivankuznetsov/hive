require "test_helper"
require "json"
require "hive/mcp/discovery"

class McpDiscoveryTest < Minitest::Test
  include HiveTestHelper

  Status = Struct.new(:exitstatus) do
    def success? = exitstatus.zero?
  end

  CODEX_ROWS = [
    {
      "name" => "linear", "auth_status" => "not_logged_in",
      "transport" => { "type" => "streamable_http", "url" => "https://mcp.linear.app/mcp" }
    },
    {
      "name" => "writero", "auth_status" => "o_auth",
      "transport" => { "type" => "streamable_http", "url" => "https://writero.app/mcp" }
    },
    {
      "name" => "docs", "auth_status" => "unsupported",
      "transport" => {
        "type" => "streamable_http", "url" => "https://docs.example.com/mcp",
        "http_headers" => { "X-Team" => "core", "Authorization" => "Bearer sekret-literal", "X-Api-Key" => "sekret-key" },
        "env_http_headers" => { "X-Org" => "ORG_ID" }
      }
    },
    {
      "name" => "internal", "auth_status" => "bearer_token",
      "transport" => {
        "type" => "streamable_http", "url" => "https://internal.example.com/mcp",
        "bearer_token_env_var" => "INTERNAL_TOKEN", "http_headers" => { "Authorization" => "Bearer ${ALT_TOKEN}" }
      }
    },
    {
      "name" => "context7", "auth_status" => "unsupported",
      "transport" => {
        "type" => "stdio", "command" => "npx", "args" => [ "-y", "ctx7" ], "cwd" => "/srv",
        "env" => { "LOG_LEVEL" => "warn", "GITHUB_TOKEN" => "sekret-gh", "REF" => "${HOST_REF}" },
        "env_vars" => [ "SHARED" ]
      }
    },
    {
      "name" => "helper", "auth_status" => "unsupported",
      "transport" => { "type" => "streamable_http", "url" => "https://h.example/mcp", "http_headers_helper" => "./h.sh" }
    },
    { "name" => "ws", "auth_status" => "unsupported", "transport" => { "type" => "websocket" } }
  ].freeze

  def capture_for(responses)
    lambda do |argv, chdir:, timeout:|
      key = argv.drop(1).join(" ")
      response = responses.fetch(key) { [ "", Status.new(127) ] }
      raise response if response.is_a?(Exception)

      response
    end
  end

  def discover(dir, responses = {}, env: {}, **more)
    responses = responses.merge(more.transform_keys(&:to_s))
    with_env({ "CODEX_HOME" => File.join(dir, "codex"), "PI_CODING_AGENT_DIR" => nil, "GROK_HOME" => nil }.merge(env)) do
      Hive::Mcp::Discovery.discover(cwd: File.join(dir, "work"), home: File.join(dir, "home"),
                                    env: ENV.to_h, capture: capture_for(responses))
    end
  end

  def write(path, content)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, content.is_a?(String) ? content : JSON.generate(content))
  end

  def by_name(result, agent)
    result.candidates.select { |candidate| candidate.agent == agent }.to_h { |candidate| [ candidate.name, candidate ] }
  end

  def test_codex_rows_map_to_catalog_entries_with_env_references_only
    with_tmp_dir do |dir|
      write(File.join(dir, "codex", "config.toml"), %([mcp_servers.writero]\noauth_resource = "https://writero.app/mcp"\n))
      result = discover(dir, "mcp list --json" => [ JSON.generate(CODEX_ROWS), Status.new(0) ])
      codex = by_name(result, "codex")

      assert codex.fetch("linear").oauth
      refute codex.fetch("linear").logged_in
      assert codex.fetch("writero").logged_in
      assert_equal "https://writero.app/mcp", codex.fetch("writero").spec.fetch("oauth_resource")
      refute codex.fetch("docs").oauth
      assert_equal({
        "url" => "https://docs.example.com/mcp", "bearer_token_env" => "DOCS_TOKEN",
        "headers" => { "X-Team" => "core" },
        "headers_env" => { "X-Org" => "ORG_ID", "X-Api-Key" => "DOCS_X_API_KEY" }
      }, codex.fetch("docs").spec)
      assert_equal %w[DOCS_TOKEN DOCS_X_API_KEY], codex.fetch("docs").exports.map { |export| export.fetch("var") }
      assert_equal "ALT_TOKEN", codex.fetch("internal").spec.fetch("bearer_token_env")
      assert_equal({
        "command" => "npx", "args" => [ "-y", "ctx7" ], "env" => { "LOG_LEVEL" => "warn" },
        "env_from" => { "SHARED" => "SHARED", "GITHUB_TOKEN" => "GITHUB_TOKEN", "REF" => "HOST_REF" }, "cwd" => "/srv"
      }, codex.fetch("context7").spec)
      assert_match(/http_headers_helper/, codex.fetch("helper").refusal)
      assert_match(/"websocket" is not supported/, codex.fetch("ws").refusal)
      refute_match(/sekret/, JSON.generate(result.candidates.map(&:to_h)))
      assert_empty result.notices.grep(/codex/)
    end
  end

  def test_unreadable_sources_are_skipped_with_notices
    with_tmp_dir do |dir|
      {
        [ "", Status.new(2) ] => "`codex mcp list --json` exited 2",
        [ "nope", Status.new(0) ] => "returned malformed JSON",
        [ "{}", Status.new(0) ] => "returned no server list",
        Errno::ENOENT.new("codex") => "codex could not run (ENOENT)",
        Hive::AgentError.new("`codex mcp list --json` timed out after 20s") => "timed out after 20s"
      }.each do |response, message|
        result = discover(dir, "mcp list --json" => response)
        assert_includes result.notices.grep(/\Acodex skipped:/).first.to_s, message
      end

      result = discover(dir, "debug config" => [ JSON.generate("mcp" => []), Status.new(0) ])
      assert_includes result.notices, "opencode skipped: `opencode debug config` returned no mcp table"

      write(File.join(dir, "home", ".claude.json"), "{broken")
      assert_match(/\Aclaude skipped: .*\.claude\.json could not be read \(ParserError\)/,
                   discover(dir).notices.grep(/claude/).first)
    end
  end

  def test_claude_scopes_merge_with_local_winning_and_detect_saved_logins
    with_tmp_dir do |dir|
      work = File.join(dir, "work")
      write(File.join(dir, "home", ".claude.json"), {
        "mcpServers" => {
          "shared" => { "type" => "http", "url" => "https://user.example/mcp" },
          "legacy" => { "type" => "sse", "url" => "https://sse.example/sse" },
          "bad" => "nope",
          "local-tool" => { "command" => "tool", "args" => [ "--serve" ] }
        },
        "projects" => { work => { "mcpServers" => { "shared" => { "type" => "http", "url" => "https://local.example/mcp" } } } }
      })
      write(File.join(work, ".mcp.json"), { "mcpServers" => { "proj" => { "type" => "http", "url" => "https://proj.example/mcp", "headers" => { "X-A" => "b" } } } })
      key = Hive::AgentSupport.for(:claude)::Mcp.login_key("proj", { "type" => "http", "url" => "https://proj.example/mcp", "headers" => { "X-A" => "b" } })
      write(File.join(dir, "home", ".claude", ".credentials.json"), { "claudeAiOauth" => {}, "mcpOAuth" => { key => { "accessToken" => "x" } } })
      claude = by_name(discover(dir), "claude")

      assert_equal "https://local.example/mcp", claude.fetch("shared").spec.fetch("url")
      assert_match(/"sse" is not supported/, claude.fetch("legacy").refusal)
      assert_match(/not an object/, claude.fetch("bad").refusal)
      assert_equal({ "command" => "tool", "args" => [ "--serve" ] }, claude.fetch("local-tool").spec)
      assert claude.fetch("proj").logged_in
      assert claude.fetch("proj").oauth
      refute claude.fetch("shared").logged_in
      assert_match(/\Aproj\|[0-9a-f]{16}\z/, key)
    end
  end

  def test_opencode_pi_and_grok_sources
    with_tmp_dir do |dir|
      opencode = {
        "mcp" => {
          "remote-one" => {
            "type" => "remote", "url" => "https://r.example/mcp", "oauth" => {},
            "headers" => { "Authorization" => "Bearer {env:R_TOKEN}", "X-Org" => "{env:R_ORG}" }
          },
          "local-one" => { "type" => "local", "command" => [ "uvx", "tool" ], "environment" => { "KEY" => "{env:HOST_KEY}" } },
          "odd" => { "type" => "sse" },
          "junk" => 5
        }
      }
      agent_dir = File.join(dir, "home", ".pi", "agent")
      write(File.join(agent_dir, "mcp.json"), {
        "mcpServers" => {
          "sentry" => { "url" => "https://mcp.sentry.dev/mcp" },
          "cmd" => { "url" => "https://c.example/mcp", "headers" => { "Authorization" => "!echo Bearer x" } },
          "fs" => { "command" => "npx", "args" => [ "fs" ], "env" => { "ROOT" => "${HOME}/x" } },
          "nope" => []
        }
      })
      write(File.join(dir, "work", ".pi", "mcp.json"), {
        "mcpServers" => { "sentry" => { "enabled" => false }, "proj-pi" => { "url" => "https://pp.example/mcp", "oauth" => {} } }
      })
      write(File.join(agent_dir, "mcp-auth.json"), { "sentry|https://mcp.sentry.dev/mcp" => { "token" => "x" } })
      write(File.join(dir, "home", ".grok", "config.toml"), <<~TOML)
        [mcp_servers.gdocs]
        url = "https://g.example/mcp"
        http_headers = { "X-Team" = "core" }

        [mcp_servers.gtool]
        command = "gtool"
        args = ["--a", "--b"]
        env = { LOG = "1", OTHER = "2" }

        [mcp_servers.gbad]
        command = "x"
        args = [1, 2]

        [mcp_servers.gbad.env]
        A = "1"

        [mcp_servers.gworse]
        command = "y"
        env = { A = 1 }

        [mcp_servers.gquote]
        command = "z"
        args = ['single']
      TOML
      result = discover(dir, "debug config" => [ JSON.generate(opencode), Status.new(0) ])
      oc = by_name(result, "opencode")
      pi = by_name(result, "pi")
      grok = by_name(result, "grok")

      assert_equal({ "url" => "https://r.example/mcp", "bearer_token_env" => "R_TOKEN", "headers_env" => { "X-Org" => "R_ORG" } },
                   oc.fetch("remote-one").spec)
      assert oc.fetch("remote-one").oauth
      assert_equal({ "command" => "uvx", "args" => [ "tool" ], "env_from" => { "KEY" => "HOST_KEY" } }, oc.fetch("local-one").spec)
      assert_match(/"sse" is not supported/, oc.fetch("odd").refusal)
      assert_match(/not an object/, oc.fetch("junk").refusal)

      assert pi.fetch("sentry").logged_in
      assert_equal({ "url" => "https://mcp.sentry.dev/mcp" }, pi.fetch("sentry").spec)
      assert_match(/not a bearer token|command/, pi.fetch("cmd").refusal)
      assert_match(/partial variable/, pi.fetch("fs").refusal)
      assert_match(/not an object/, pi.fetch("nope").refusal)
      assert pi.fetch("proj-pi").oauth

      assert_equal({ "url" => "https://g.example/mcp", "headers" => { "X-Team" => "core" } }, grok.fetch("gdocs").spec)
      assert_equal({ "command" => "gtool", "args" => %w[--a --b], "env" => { "LOG" => "1", "OTHER" => "2" } },
                   grok.fetch("gtool").spec)
      assert_match(/cannot read/, grok.fetch("gbad").refusal)
      assert_match(/cannot read/, grok.fetch("gworse").refusal)
      assert_match(/cannot read/, grok.fetch("gquote").refusal)
    end
  end

  def test_unreadable_grok_config_is_skipped_and_missing_sources_are_empty
    with_tmp_dir do |dir|
      assert_empty discover(dir).candidates
      path = File.join(dir, "home", ".grok", "config.toml")
      write(path, "")
      File.chmod(0o000, path)
      skip "running as root" if File.readable?(path)

      assert_includes discover(dir).notices, "grok skipped: #{path} is not readable"
    ensure
      File.chmod(0o600, path) if path && File.exist?(path)
    end
  end

  def test_literal_values_that_cannot_be_referenced_are_refused
    with_tmp_dir do |dir|
      rows = [
        { "name" => "basic", "auth_status" => "unsupported",
          "transport" => { "type" => "streamable_http", "url" => "https://b.example/mcp", "http_headers" => { "Authorization" => "Basic abc" } } },
        { "name" => "partial", "auth_status" => "unsupported",
          "transport" => { "type" => "streamable_http", "url" => "https://p.example/mcp", "http_headers" => { "X-Org" => "org-${ORG}" } } },
        { "name" => "badurl", "auth_status" => "unsupported",
          "transport" => { "type" => "streamable_http", "url" => "ftp://x" } }
      ]
      codex = by_name(discover(dir, "mcp list --json" => [ JSON.generate(rows), Status.new(0) ]), "codex")

      assert_equal "its Authorization header is not a bearer token", codex.fetch("basic").refusal
      assert_match(/X-Org header builds its value/, codex.fetch("partial").refusal)
      assert_match(/badurl.url in codex MCP config must be/, codex.fetch("badurl").refusal)
      refute_match(/defaults; no file present/, codex.fetch("badurl").refusal)
    end
  end
end
