require "test_helper"
require "hive/canonical_json"

class CanonicalJSONTest < Minitest::Test
  def test_normalizes_nested_keys_symbols_and_times
    time = Time.utc(2026, 9, 4, 12, 30, 45, 123_456)

    assert_equal(
      %({"items":["ready",{"at":"2026-09-04T12:30:45.123456Z"}]}),
      Hive::CanonicalJSON.generate(items: [ :ready, { at: time } ])
    )
  end
end
