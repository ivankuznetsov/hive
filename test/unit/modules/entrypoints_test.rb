require "test_helper"
require "hive/modules/entrypoints"

class ModulesEntrypointsTest < Minitest::Test
  def teardown
    Hive::Modules::Entrypoints.reset!
    super
  end

  def test_registration_requires_a_stable_id_and_callable
    assert_raises(ArgumentError) { Hive::Modules::Entrypoints.register("INVALID", -> { }) }
    assert_raises(ArgumentError) { Hive::Modules::Entrypoints.register("demo.run", Object.new) }
    assert_raises(Hive::ConfigError) { Hive::Modules::Entrypoints.fetch("missing") }

    handler = -> { :ok }
    Hive::Modules::Entrypoints.register("demo.run", handler)
    assert_same handler, Hive::Modules::Entrypoints.fetch("demo.run")
  end
end
