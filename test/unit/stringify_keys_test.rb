require "test_helper"
require "hive/stringify_keys"

class StringifyKeysTest < Minitest::Test
  def test_recurses_through_hashes_and_arrays_without_mutating_values
    input = { "root" => [ { "nested" => [ :value ] } ], count: 2 }

    result = Hive::StringifyKeys.call(input)

    assert_equal({ "root" => [ { "nested" => [ :value ] } ], "count" => 2 }, result)
    result.fetch("root").first.fetch("nested") << :changed

    assert_equal({ "root" => [ { "nested" => [ :value ] } ], count: 2 }, input)
    assert_equal({ "root" => [ { "nested" => [ :value ] } ], "count" => 2 },
                 Hive::StringifyKeys.call(input))
  end
end
