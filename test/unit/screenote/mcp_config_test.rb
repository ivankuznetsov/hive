require "test_helper"
require "hive/screenote/mcp_config"

class ScreenoteMcpConfigTest < Minitest::Test
  include HiveTestHelper

  def credential
    {
      "access_token" => "access-123",
      "mcp_resource" => "https://screenote.test/mcp"
    }
  end

  def test_payload_builds_screenote_http_server_with_bearer_header
    payload = Hive::Screenote::McpConfig.new(credential: credential).payload

    server = payload.dig("mcpServers", "screenote")
    assert_equal "http", server["type"]
    assert_equal "https://screenote.test/mcp", server["url"]
    assert_equal "Bearer access-123", server.dig("headers", "Authorization")
  end

  def test_allowed_tools_csv_merges_and_deduplicates_tool_names
    tools = Hive::Screenote::McpConfig.allowed_tools_csv(
      "Read,mcp__screenote__list_projects,Bash"
    ).split(",")

    assert_equal 1, tools.count("mcp__screenote__list_projects")
    assert_includes tools, "Read"
    assert_includes tools, "Bash"
    assert_includes tools, "mcp__screenote__create_screenshot_upload"
    assert_includes tools, "mcp__screenote__create_multi_viewport_screenshot"
  end

  def test_write_creates_secure_cache_file_under_hive_cache_home
    with_tmp_dir do |dir|
      with_env("HIVE_HOME" => dir) do
        path = Hive::Screenote::McpConfig.new(credential: credential).write!

        assert_match(%r{\A#{Regexp.escape(File.join(dir, "mcp"))}}, path)
        assert_equal 0o600, File.stat(path).mode & 0o777
        assert_equal "Bearer access-123",
                     JSON.parse(File.read(path)).dig("mcpServers", "screenote", "headers", "Authorization")
      end
    end
  end

  def test_missing_required_credential_fields_raise_config_error
    err = assert_raises(Hive::ConfigError) do
      Hive::Screenote::McpConfig.new(credential: credential.merge("access_token" => "")).payload
    end
    assert_match(/missing access_token/, err.message)

    err = assert_raises(Hive::ConfigError) do
      Hive::Screenote::McpConfig.new(credential: credential.merge("mcp_resource" => "")).payload
    end
    assert_match(/missing mcp_resource/, err.message)
  end
end
