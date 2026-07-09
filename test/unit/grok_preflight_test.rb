require "test_helper"
require "hive/agent_profiles"

# Coverage for the grok profile's GROK_PREFLIGHT lambda and usage extractor —
# every error path translates to Hive::AgentError (same contract as pi's).
class GrokPreflightTest < Minitest::Test
  include HiveTestHelper

  def with_fake_grok_home
    Dir.mktmpdir("fake-grok-home") do |home|
      FileUtils.mkdir_p(File.join(home, ".grok"))
      prev_home = ENV["HOME"]
      ENV["HOME"] = home
      begin
        yield(home)
      ensure
        ENV["HOME"] = prev_home
      end
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

  def test_translates_home_resolution_failure_to_agent_error
    original_expand_path = File.method(:expand_path)
    File.define_singleton_method(:expand_path) do |target, *args|
      raise ArgumentError, "could not find home directory" if target == "~/.grok/auth.json"

      original_expand_path.call(target, *args)
    end
    err = assert_raises(Hive::AgentError) { Hive::AgentProfiles::GROK_PREFLIGHT.call }

    assert_match(/cannot resolve home directory/, err.message)
  ensure
    File.define_singleton_method(:expand_path, original_expand_path) if original_expand_path
  end

  def test_passes_with_real_credential
    with_fake_grok_home do |home|
      File.write(auth_path_for(home), '{"access_token":"x"}')
      assert_nil Hive::AgentProfiles::GROK_PREFLIGHT.call
    end
  end

  def test_usage_extractor_zeroes_on_end_event
    result = Hive::AgentProfiles::UsageExtractors::GROK.call({ "type" => "end" })

    refute_nil result
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
