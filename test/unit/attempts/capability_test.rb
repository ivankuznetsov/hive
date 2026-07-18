require "test_helper"
require "hive/attempts/capability"

class AttemptsCapabilityTest < Minitest::Test
  def test_generate_returns_a_valid_random_secret
    first = Hive::Attempts::Capability.generate
    second = Hive::Attempts::Capability.generate

    assert Hive::Attempts::Capability.valid_secret?(first)
    assert Hive::Attempts::Capability.valid_secret?(second)
    refute_equal first, second
  end
end
