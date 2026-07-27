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

  def test_unknown_provider_exits_64_with_typed_message
    _out, err, status = run_cli("probe", "not-a-provider", "--json")

    assert_equal 64, status.exitstatus
    assert_match(/unknown provider/, err)
    assert_match(/claude, codex, pi, grok/, err)
    assert_match(/Usage:/, err)
  end

  def test_unknown_option_exits_64
    _out, err, status = run_cli("probe", "codex", "--yaml")

    assert_equal 64, status.exitstatus
    assert_match(/Usage:/, err)
  end

  def test_ready_json_probe_has_the_complete_v1_shape
    Dir.mktmpdir do |dir|
      bin = File.join(dir, "codex")
      write_executable(bin, <<~SH)
        #!/bin/sh
        printf '%s\n' 'codex-cli 0.125.0'
      SH
      out, err, status = Open3.capture3(
        {
          "PATH" => "/usr/bin:/bin",
          "RUBYLIB" => LIB,
          "OPENAI_API_KEY" => "configured",
          "AGENT_CLI_RUNTIME_CODEX_BIN" => bin
        },
        Gem.ruby, EXE, "probe", "codex", "--json"
      )

      assert_equal 0, status.exitstatus
      assert_empty err
      payload = JSON.parse(out)
      assert_equal %w[probes schema_version], payload.keys.sort
      probe = payload.fetch("probes").fetch(0)
      assert_equal %w[
        auth_configuration capabilities diagnostic executable installed
        minimum_version provider ready version
      ], probe.keys.sort
      assert_equal %w[source status],
                   probe.fetch("auth_configuration").keys.sort
      assert_equal(
        %w[
          headless version auth_configuration add_directory allowed_tools
          disallowed_tools model effort budget raw_cli_arguments installation
        ],
        probe.fetch("capabilities").map { |item| item.fetch("capability") }
      )
      assert(
        probe.fetch("capabilities").all? do |item|
          item.keys.sort == %w[capability supported]
        end
      )
    end
  end

  private

  def run_cli(*arguments)
    Open3.capture3(
      { "PATH" => "/usr/bin:/bin", "RUBYLIB" => LIB },
      Gem.ruby, EXE, *arguments
    )
  end
end
