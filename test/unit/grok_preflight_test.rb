require "test_helper"
require "hive/agent_runtime"

class GrokPreflightTest < Minitest::Test
  include HiveTestHelper

  def test_hive_grok_profile_uses_the_package_profile
    assert_same AgentCliRuntime::Profiles.fetch(:grok),
                Hive::AgentProfiles.lookup(:grok).runtime_profile
    refute Hive::AgentProfiles.const_defined?(:GROK_PREFLIGHT, false)
  end

  def test_package_auth_probe_owns_grok_session_path_validation
    profile = Hive::AgentProfiles.lookup(:grok).runtime_profile
    auth = profile.auth_configuration(
      home: "/unused",
      env: { "GROK_AUTH_PATH" => "relative/auth.json" }
    )

    assert_equal :missing, auth.status
    assert_includes auth.diagnostic, "GROK_AUTH_PATH must be absolute"
  end

  def test_package_auth_probe_distinguishes_missing_and_configured_sessions
    with_tmp_dir do |home|
      profile = Hive::AgentProfiles.lookup(:grok).runtime_profile
      auth_dir = File.join(home, ".grok")
      FileUtils.mkdir_p(auth_dir)
      path = File.join(auth_dir, "auth.json")

      assert_equal :missing,
                   profile.auth_configuration(home:, env: {}).status
      File.write(path, "{}")
      assert_equal :missing,
                   profile.auth_configuration(home:, env: {}).status
      File.write(path, '{"session":"configured"}')
      assert_equal :configured,
                   profile.auth_configuration(home:, env: {}).status
    end
  end

  def test_hive_prepare_delegates_grok_prerequisite_failure_to_package
    with_grok_fixture(auth: nil) do |environment|
      with_env(environment) do
        error = assert_raises(Hive::AgentRuntime::ProbeError) do
          Hive::AgentRuntime.prepare!(Hive::AgentProfiles.lookup(:grok))
        end
        assert_equal :probe, error.evidence.capability
      end
    end
  end

  def test_hive_prepare_does_not_treat_an_api_key_as_a_subscription_session
    with_grok_fixture(auth: nil) do |environment|
      with_env(environment.merge("XAI_API_KEY" => "unused-api-key")) do
        assert_raises(Hive::AgentRuntime::ProbeError) do
          Hive::AgentRuntime.prepare!(Hive::AgentProfiles.lookup(:grok))
        end
      end
    end
  end

  def test_hive_prepare_accepts_configured_grok_subscription
    with_grok_fixture(auth: '{"session":"configured"}') do |environment|
      with_env(environment) do
        result = Hive::AgentRuntime.prepare!(Hive::AgentProfiles.lookup(:grok))
        assert_equal :grok, result.provider
        assert_equal "99.0.0", result.version
      end
    end
  end

  private

  def with_grok_fixture(auth:)
    with_tmp_dir do |home|
      bin = File.join(home, "grok")
      File.write(bin, "#!/bin/sh\nprintf '%s\\n' 'grok 99.0.0'\n")
      FileUtils.chmod(0o755, bin)
      auth_dir = File.join(home, ".grok")
      FileUtils.mkdir_p(auth_dir)
      File.write(File.join(auth_dir, "auth.json"), auth) if auth
      yield(
        "HOME" => home, "HIVE_GROK_BIN" => bin,
        "GROK_AUTH_PATH" => nil, "GROK_HOME" => nil,
        "XAI_API_KEY" => nil, "GROK_CODE_XAI_API_KEY" => nil
      )
    end
  end
end
