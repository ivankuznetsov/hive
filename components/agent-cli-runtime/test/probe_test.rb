require_relative "test_helper"

class AgentCliRuntimeProbeTest < Minitest::Test
  def test_ready_probe_reports_only_local_observations
    Dir.mktmpdir do |dir|
      bin = File.join(dir, "fixture-agent")
      write_executable(bin, <<~RUBY)
        #!/usr/bin/env ruby
        puts "fixture-agent 1.2.3"
      RUBY
      profile = AgentCliRuntime::Profile.new(
        name: :fixture,
        bin_default: bin,
        headless_flag: "-p",
        version_flag: "--version",
        min_version: "1.0.0",
        auth_configuration_probe: ->(**) {
          AgentCliRuntime::AuthConfiguration.new(status: :configured, source: "fixture")
        }
      )

      result = AgentCliRuntime.probe(profile)

      assert result.ready
      assert result.installed
      assert_equal "1.2.3", result.version
      assert_equal :configured, result.auth_configuration.status
      assert_nil result.diagnostic
      refute_respond_to result, :healthy
      refute_respond_to result, :quota
      refute_respond_to result, :credentials_valid
    end
  end

  def test_missing_binary_is_fail_soft_and_typed
    profile = AgentCliRuntime::Profile.new(
      name: :missing,
      bin_default: "/definitely/missing/agent",
      headless_flag: "-p",
      version_flag: "--version"
    )

    result = AgentCliRuntime.probe(profile)

    refute result.ready
    refute result.installed
    assert_nil result.version
    assert_equal :not_checked, result.auth_configuration.status
    assert_match(/not runnable/, result.diagnostic)
  end

  def test_probe_all_uses_stable_provider_order
    results = AgentCliRuntime.probe_all

    assert_equal %i[claude codex pi grok], results.map(&:provider)
  end
end
