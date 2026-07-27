require "test_helper"
require "hive/agent_profiles"

# Coverage for the grok profile's GROK_PREFLIGHT lambda and usage extractor —
# every error path translates to Hive::AgentError (same contract as pi's).
class GrokPreflightTest < Minitest::Test
  include HiveTestHelper

  def with_fake_grok_home
    Dir.mktmpdir("fake-grok-home") do |home|
      FileUtils.mkdir_p(File.join(home, ".grok"))
      with_env(
        "HOME" => home,
        "GROK_AUTH_PATH" => nil,
        "GROK_HOME" => nil,
        "XAI_API_KEY" => nil,
        "GROK_CODE_XAI_API_KEY" => nil
      ) { yield(home) }
    end
  end

  def auth_path_for(home)
    File.join(home, ".grok", "auth.json")
  end

  def test_raises_when_auth_file_missing
    with_fake_grok_home do |_home|
      err = assert_raises(Hive::AgentError) { Hive::AgentProfiles::GROK_PREFLIGHT.call }
      assert_match(/auth\.json not found/, err.message)
      assert_match(/grok login/, err.message)
    end
  end

  def test_raises_when_auth_file_empty
    with_fake_grok_home do |home|
      File.write(auth_path_for(home), "")
      err = assert_raises(Hive::AgentError) { Hive::AgentProfiles::GROK_PREFLIGHT.call }
      assert_match(/no credential/, err.message)
    end
  end

  def test_raises_when_auth_file_is_empty_object
    with_fake_grok_home do |home|
      File.write(auth_path_for(home), "{  }")
      err = assert_raises(Hive::AgentError) { Hive::AgentProfiles::GROK_PREFLIGHT.call }
      assert_match(/no credential/, err.message)
    end
  end

  def test_raises_when_auth_file_unreadable
    skip "running as root: file mode 000 still readable" if Process.uid.zero?

    with_fake_grok_home do |home|
      File.write(auth_path_for(home), '{"access_token":"x"}')
      File.chmod(0o000, auth_path_for(home))
      err = assert_raises(Hive::AgentError) { Hive::AgentProfiles::GROK_PREFLIGHT.call }
      assert_match(/cannot read/, err.message)
    ensure
      File.chmod(0o600, auth_path_for(home))
    end
  end

  def test_rejects_relative_grok_auth_path
    err = with_env(
      "GROK_AUTH_PATH" => "relative/auth.json",
      "XAI_API_KEY" => nil,
      "GROK_CODE_XAI_API_KEY" => nil
    ) do
      assert_raises(Hive::AgentError) { Hive::AgentProfiles::GROK_PREFLIGHT.call }
    end

    assert_match(/GROK_AUTH_PATH must be absolute/, err.message)
  end

  def test_ignores_unused_relative_grok_auth_path_with_api_key
    with_env("GROK_AUTH_PATH" => "relative/auth.json", "XAI_API_KEY" => "test-key") do
      assert_nil Hive::AgentProfiles::GROK_PREFLIGHT.call
    end
  end

  def test_rejects_relative_grok_home
    err = with_env("GROK_AUTH_PATH" => nil, "GROK_HOME" => "relative/grok-home") do
      assert_raises(Hive::AgentError) { Hive::AgentProfiles::GROK_PREFLIGHT.call }
    end

    assert_match(/GROK_HOME must be absolute/, err.message)
  end

  def test_ignores_unused_relative_grok_home_with_api_key
    with_env(
      "GROK_AUTH_PATH" => "relative/auth.json",
      "GROK_HOME" => "relative/grok-home",
      "XAI_API_KEY" => "test-key"
    ) do
      assert_nil Hive::AgentProfiles::GROK_PREFLIGHT.call
    end
  end

  def test_passes_with_real_credential
    with_fake_grok_home do |home|
      File.write(auth_path_for(home), '{"access_token":"x"}')
      assert_nil Hive::AgentProfiles::GROK_PREFLIGHT.call
    end
  end

  def test_passes_with_xai_api_key_without_auth_file
    with_fake_grok_home do
      with_env("XAI_API_KEY" => "test-key") do
        assert_nil Hive::AgentProfiles::GROK_PREFLIGHT.call
      end
    end
  end

  def test_uses_grok_home_for_auth_file
    with_fake_grok_home do
      Dir.mktmpdir("custom-grok-home") do |grok_home|
        File.write(File.join(grok_home, "auth.json"), '{"access_token":"x"}')

        with_env("GROK_HOME" => grok_home) do
          assert_nil Hive::AgentProfiles::GROK_PREFLIGHT.call
        end
      end
    end
  end

  def test_grok_auth_path_overrides_grok_home
    with_fake_grok_home do
      Dir.mktmpdir("shared-grok-auth") do |auth_dir|
        auth_path = File.join(auth_dir, "benchmark-auth.json")
        File.write(auth_path, '{"access_token":"x"}')

        with_env("GROK_AUTH_PATH" => auth_path, "GROK_HOME" => "/missing/grok-home") do
          assert_nil Hive::AgentProfiles::GROK_PREFLIGHT.call
        end
      end
    end
  end

  def test_explicit_auth_locations_do_not_require_home_resolution
    Dir.mktmpdir("shared-grok-auth") do |auth_dir|
      auth_path = File.join(auth_dir, "benchmark-auth.json")
      File.write(auth_path, '{"access_token":"x"}')
      grok_home = File.join(auth_dir, "grok-home")
      FileUtils.mkdir_p(grok_home)
      File.write(File.join(grok_home, "auth.json"), '{"access_token":"x"}')

      with_replaced_singleton_method(Dir, :home, -> { raise ArgumentError, "no home" }) do
        with_env(
          "GROK_AUTH_PATH" => auth_path,
          "GROK_HOME" => nil,
          "XAI_API_KEY" => nil,
          "GROK_CODE_XAI_API_KEY" => nil
        ) { assert_nil Hive::AgentProfiles::GROK_PREFLIGHT.call }

        with_env(
          "GROK_AUTH_PATH" => nil,
          "GROK_HOME" => grok_home,
          "XAI_API_KEY" => nil,
          "GROK_CODE_XAI_API_KEY" => nil
        ) { assert_nil Hive::AgentProfiles::GROK_PREFLIGHT.call }
      end
    end
  end

  def test_missing_grok_auth_path_does_not_fall_back_to_grok_home
    with_fake_grok_home do
      Dir.mktmpdir("custom-grok-home") do |grok_home|
        File.write(File.join(grok_home, "auth.json"), '{"access_token":"x"}')
        missing = File.join(grok_home, "missing-auth.json")

        with_env("GROK_AUTH_PATH" => missing, "GROK_HOME" => grok_home) do
          err = assert_raises(Hive::AgentError) { Hive::AgentProfiles::GROK_PREFLIGHT.call }
          assert_match(/#{Regexp.escape(missing)} not found/, err.message)
        end
      end
    end
  end

  def test_usage_extractor_does_not_fabricate_zeroes_on_end_event
    assert_nil Hive::AgentProfiles::UsageExtractors::GROK.call({ "type" => "end" })
  end

  def test_usage_extractor_ignores_non_hash_and_mid_stream_events
    assert_nil Hive::AgentProfiles::UsageExtractors::GROK.call("text")
    assert_nil Hive::AgentProfiles::UsageExtractors::GROK.call({ "type" => "thought" })
  end

  def test_usage_extractor_reads_usage_when_present
    event = { "type" => "end", "usage" => { "input_tokens" => 5, "output_tokens" => 2 } }
    result = Hive::AgentProfiles::UsageExtractors::GROK.call(event)

    refute_nil result
  end
end
