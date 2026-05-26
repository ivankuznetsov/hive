require "test_helper"
require "hive/babysitter/interval"

class BabysitterIntervalTest < Minitest::Test
  def test_parse_integer_seconds
    assert_equal 30, Hive::Babysitter::Interval.parse(30)
  end

  def test_parse_duration_strings
    assert_equal 30, Hive::Babysitter::Interval.parse("30s")
    assert_equal 600, Hive::Babysitter::Interval.parse("10m")
    assert_equal 7200, Hive::Babysitter::Interval.parse("2h")
  end

  def test_rejects_invalid_interval
    err = assert_raises(Hive::ConfigError) { Hive::Babysitter::Interval.parse("10x") }
    assert_match(/babysitter\.interval/, err.message)
  end
end
