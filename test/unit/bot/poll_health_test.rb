require "test_helper"
require "hive/bot/poll_health"

class HiveBotPollHealthTest < Minitest::Test
  def test_consecutive_failures_escalate_once_until_success
    now = Time.utc(2026, 6, 24, 12, 0, 0)
    health = Hive::Bot::PollHealth.new(now: -> { now }, max_consecutive: 3, max_silence_sec: 60)

    refute health.record_failure.escalate?
    refute health.record_failure.escalate?
    result = health.record_failure

    assert result.escalate?
    assert_equal :consecutive, result.reason
    assert_equal 3, result.consecutive_failures
    refute health.record_failure.escalate?, "sustained outage should not emit a loud line every poll"

    health.record_success
    refute health.record_failure.escalate?
    refute health.record_failure.escalate?
    assert health.record_failure.escalate?, "success should re-arm a later unhealthy episode"
  end

  def test_success_resets_consecutive_count
    now = Time.utc(2026, 6, 24, 12, 0, 0)
    health = Hive::Bot::PollHealth.new(now: -> { now }, max_consecutive: 2, max_silence_sec: 60)

    refute health.record_failure.escalate?
    health.record_success
    result = health.record_failure

    refute result.escalate?
    assert_equal 1, result.consecutive_failures
  end

  def test_silence_escalates_even_before_consecutive_threshold
    now = Time.utc(2026, 6, 24, 12, 0, 0)
    health = Hive::Bot::PollHealth.new(now: -> { now }, max_consecutive: 5, max_silence_sec: 10)
    now += 11

    result = health.record_failure

    assert result.escalate?
    assert_equal :silence, result.reason
    assert_equal 1, result.consecutive_failures
    assert_equal 11, result.seconds_since_success
    refute health.record_failure.escalate?
  end

  def test_success_resets_silence_window
    now = Time.utc(2026, 6, 24, 12, 0, 0)
    health = Hive::Bot::PollHealth.new(now: -> { now }, max_consecutive: 5, max_silence_sec: 10)
    now += 11
    assert health.record_failure.escalate?

    health.record_success
    now += 9
    refute health.record_failure.escalate?
    now += 1
    assert health.record_failure.escalate?
  end
end
