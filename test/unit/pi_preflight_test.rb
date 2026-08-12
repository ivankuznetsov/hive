require "test_helper"
require "hive/agent_runtime"

class PiPreflightTest < Minitest::Test
  include HiveTestHelper

  def test_hive_pi_profile_uses_the_package_profile
    assert_same AgentCliRuntime::Profiles.fetch(:pi),
                Hive::AgentProfiles.lookup(:pi).runtime_profile
    refute Hive::AgentProfiles.const_defined?(:PI_PREFLIGHT, false)
  end

  def test_package_auth_probe_distinguishes_missing_and_configured_sessions
    with_tmp_dir do |home|
      profile = Hive::AgentProfiles.lookup(:pi).runtime_profile
      auth_dir = File.join(home, ".pi", "agent")
      FileUtils.mkdir_p(auth_dir)
      path = File.join(auth_dir, "auth.json")

      assert_equal :missing,
                   profile.auth_configuration(home:, env: {}).status
      File.write(path, "{  }")
      assert_equal :missing,
                   profile.auth_configuration(home:, env: {}).status
      File.write(path, '{"provider":"configured"}')
      assert_equal :configured,
                   profile.auth_configuration(home:, env: {}).status
    end
  end

  def test_hive_prepare_delegates_pi_prerequisite_failure_to_package
    with_pi_fixture(auth: nil) do |environment|
      with_env(environment) do
        error = assert_raises(Hive::AgentRuntime::ProbeError) do
          Hive::AgentRuntime.prepare!(Hive::AgentProfiles.lookup(:pi))
        end
        assert_equal :probe, error.evidence.capability
      end
    end
  end

  def test_hive_prepare_accepts_configured_pi_subscription
    with_pi_fixture(auth: '{"provider":"configured"}') do |environment|
      with_env(environment) do
        result = Hive::AgentRuntime.prepare!(Hive::AgentProfiles.lookup(:pi))
        assert_equal :pi, result.provider
        assert_equal "99.0.0", result.version
      end
    end
  end

  private

  def with_pi_fixture(auth:)
    with_tmp_dir do |home|
      bin = File.join(home, "pi")
      File.write(bin, "#!/bin/sh\nprintf '%s\\n' 'pi 99.0.0'\n")
      FileUtils.chmod(0o755, bin)
      auth_dir = File.join(home, ".pi", "agent")
      FileUtils.mkdir_p(auth_dir)
      File.write(File.join(auth_dir, "auth.json"), auth) if auth
      yield("HOME" => home, "HIVE_PI_BIN" => bin,
            "PI_CODING_AGENT_DIR" => nil)
    end
  end
end
