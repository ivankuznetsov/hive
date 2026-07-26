require_relative "test_helper"

class AgentCliRuntimeCliTest < Minitest::Test
  EXE = File.expand_path("../exe/agent-runtime", __dir__)
  LIB = File.expand_path("../lib", __dir__)

  def test_json_probe_uses_versioned_envelope_and_unavailable_exit
    out, err, status = Open3.capture3(
      {
        "PATH" => "/usr/bin:/bin",
        "RUBYLIB" => LIB,
        "AGENT_CLI_RUNTIME_CODEX_BIN" => "/missing/codex"
      },
      Gem.ruby, EXE, "probe", "codex", "--json"
    )

    assert_equal 1, status.exitstatus
    assert_empty err
    payload = JSON.parse(out)
    assert_equal 1, payload.fetch("schema_version")
    assert_equal [ "codex" ], payload.fetch("probes").map { |probe| probe.fetch("provider") }
    assert_equal false, payload.dig("probes", 0, "ready")
    refute payload.dig("probes", 0).key?("healthy")
    refute payload.dig("probes", 0).key?("quota")
    refute payload.dig("probes", 0).key?("credentials_valid")
  end

  def test_all_json_probe_preserves_provider_order
    out, _err, status = Open3.capture3(
      { "PATH" => "/usr/bin:/bin", "RUBYLIB" => LIB },
      Gem.ruby, EXE, "probe", "--all", "--json"
    )

    assert_includes [ 0, 1 ], status.exitstatus
    payload = JSON.parse(out)
    assert_equal %w[claude codex pi grok],
                 payload.fetch("probes").map { |probe| probe.fetch("provider") }
  end

  def test_invalid_usage_exits_64_without_probing
    _out, err, status = Open3.capture3(
      { "PATH" => "/usr/bin:/bin", "RUBYLIB" => LIB },
      Gem.ruby, EXE, "probe", "codex", "--all"
    )

    assert_equal 64, status.exitstatus
    assert_match(/Usage:/, err)
  end
end
