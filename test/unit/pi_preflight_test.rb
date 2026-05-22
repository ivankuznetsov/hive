require "test_helper"
require "hive/agent_profiles"

# Coverage for the pi profile's PI_PREFLIGHT lambda. Closes doc-review
# finding #3 — every error path translates to Hive::AgentError so callers
# only need to rescue one error class.
class PiPreflightTest < Minitest::Test
  include HiveTestHelper

  def with_fake_pi_home
    Dir.mktmpdir("fake-pi-home") do |home|
      FileUtils.mkdir_p(File.join(home, ".pi", "agent"))
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
    File.join(home, ".pi", "agent", "auth.json")
  end

  def test_raises_when_auth_file_missing
    with_fake_pi_home do |_home|
      err = assert_raises(Hive::AgentError) { Hive::AgentProfiles::PI_PREFLIGHT.call }
      assert_match(/auth\.json not found/, err.message)
      assert_match(/Run `pi` interactively/, err.message)
    end
  end

  def test_raises_when_auth_file_empty
    with_fake_pi_home do |home|
      File.write(auth_path_for(home), "")
      err = assert_raises(Hive::AgentError) { Hive::AgentProfiles::PI_PREFLIGHT.call }
      assert_match(/no provider configured/, err.message)
    end
  end

  def test_raises_when_auth_file_is_empty_object
    with_fake_pi_home do |home|
      File.write(auth_path_for(home), "{}")
      err = assert_raises(Hive::AgentError) { Hive::AgentProfiles::PI_PREFLIGHT.call }
      assert_match(/no provider configured/, err.message)
    end
  end

  def test_raises_when_auth_file_is_whitespace_padded_empty_object
    with_fake_pi_home do |home|
      File.write(auth_path_for(home), "  {  }  \n")
      err = assert_raises(Hive::AgentError) { Hive::AgentProfiles::PI_PREFLIGHT.call }
      assert_match(/no provider configured/, err.message)
    end
  end

  def test_returns_nil_when_auth_file_has_real_content
    with_fake_pi_home do |home|
      File.write(auth_path_for(home), %({"provider":"google","token":"abc"}))
      assert_nil Hive::AgentProfiles::PI_PREFLIGHT.call
    end
  end

  def test_translates_home_resolution_failure_to_agent_error
    original_expand_path = File.method(:expand_path)
    File.define_singleton_method(:expand_path) do |target, *args|
      if target == "~/.pi/agent/auth.json"
        raise ArgumentError, "could not find home directory"
      end

      original_expand_path.call(target, *args)
    end

    err = assert_raises(Hive::AgentError) { Hive::AgentProfiles::PI_PREFLIGHT.call }
    assert_match(/cannot resolve home directory/, err.message)
    assert_match(/Set \$HOME/, err.message)
  ensure
    File.define_singleton_method(:expand_path, original_expand_path) if original_expand_path
  end

  def test_translates_unreadable_auth_file_to_agent_error
    skip "running as root: file mode 000 still readable" if Process.uid.zero?

    with_fake_pi_home do |home|
      path = auth_path_for(home)
      File.write(path, "{}")
      File.chmod(0o000, path)
      begin
        err = assert_raises(Hive::AgentError) { Hive::AgentProfiles::PI_PREFLIGHT.call }
        # Either "cannot read" (Errno::EACCES caught) or "no provider"
        # (if File.read somehow succeeds in a test env). Both translate
        # to AgentError, which is the contract.
        assert_match(/cannot read|no provider configured/, err.message)
      ensure
        File.chmod(0o600, path) # restore so the tmpdir cleanup can rm
      end
    end
  end
end
