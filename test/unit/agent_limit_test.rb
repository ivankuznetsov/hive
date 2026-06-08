require "test_helper"
require "time"
require "hive/agent_limit"

class AgentLimitTest < Minitest::Test
  def test_detects_claude_usage_limit_menu
    text = <<~TEXT
      What do you want to do?
      ❯ 1. Stop and wait for limit to reset
        2. Add funds to continue with usage credits
        3. Switch to Team plan
    TEXT

    assert Hive::AgentLimit.limit_reached?(text)
    assert_match(/\Alimits reached for claude:/,
                 Hive::AgentLimit.error_message(text, agent: "claude"))
  end

  def test_detects_common_provider_quota_errors
    assert Hive::AgentLimit.limit_reached?("Error: RESOURCE_EXHAUSTED: quota exceeded")
    assert Hive::AgentLimit.limit_reached?("429 Too Many Requests")
    assert Hive::AgentLimit.limit_reached?("insufficient_quota")
  end

  def test_does_not_classify_unrelated_errors_as_limits
    refute Hive::AgentLimit.limit_reached?("tmux session terminated before writing expected output")
    refute Hive::AgentLimit.limit_reached?("exit_code=1")
    refute Hive::AgentLimit.limit_reached?("429        hive_state = File.join(project_root, \".hive-state\")")
    refute Hive::AgentLimit.limit_reached?("error output includes source line 429        hive_state = path")
    refute Hive::AgentLimit.limit_reached?("missing rate limit on /api/upload")
  end

  def test_retry_after_is_default_cooldown_in_the_future
    now = Time.utc(2026, 6, 8, 12, 0, 0)
    stamp = Hive::AgentLimit.retry_after(now: now)

    assert_equal (now + Hive::AgentLimit::RETRY_COOLDOWN_SEC).iso8601, stamp
    assert Time.parse(stamp) > now, "retry_after must be in the future"
  end

  def test_retry_after_normalizes_a_non_utc_now_to_utc
    now = Time.new(2026, 6, 8, 12, 0, 0, "+05:00")
    stamp = Hive::AgentLimit.retry_after(now: now)

    assert_equal (now.utc + Hive::AgentLimit::RETRY_COOLDOWN_SEC).iso8601, stamp
    assert_match(/Z\z/, stamp, "stamp must be serialized in UTC")
  end

  def test_retry_cooldown_sec_honors_a_positive_env_override
    with_env("HIVE_LIMITS_RETRY_COOLDOWN_SEC" => "120") do
      assert_equal 120, Hive::AgentLimit.retry_cooldown_sec
      now = Time.utc(2026, 6, 8, 12, 0, 0)
      assert_equal (now + 120).iso8601, Hive::AgentLimit.retry_after(now: now)
    end
  end

  def test_retry_cooldown_sec_falls_back_on_unparseable_or_non_positive_override
    [ "not-a-number", "0", "-5", "" ].each do |bad|
      with_env("HIVE_LIMITS_RETRY_COOLDOWN_SEC" => bad) do
        assert_equal Hive::AgentLimit::RETRY_COOLDOWN_SEC, Hive::AgentLimit.retry_cooldown_sec,
                     "override #{bad.inspect} must fall back to the default cooldown"
      end
    end
  end

  def test_retry_cooldown_sec_uses_default_when_env_is_unset
    with_env("HIVE_LIMITS_RETRY_COOLDOWN_SEC" => nil) do
      assert_equal Hive::AgentLimit::RETRY_COOLDOWN_SEC, Hive::AgentLimit.retry_cooldown_sec
    end
  end

  private

  def with_env(values)
    original = values.keys.to_h { |key| [ key, ENV[key] ] }
    values.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
    yield
  ensure
    original.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
  end
end
