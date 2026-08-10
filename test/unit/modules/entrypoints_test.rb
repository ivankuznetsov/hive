require "test_helper"
require "hive/modules/entrypoints"
require "hive/modules/first_party"

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

  def test_first_party_loader_registers_adapter_entrypoints_with_bound_hook_ids
    calls = []
    patrol_class = Class.new do
      const_set(:ENTRYPOINTS, { "fake.patrol" => "scheduled-scan" }.freeze)
      define_method(:initialize) { |sink| @sink = sink }
      define_method(:call) { |**context| @sink << context; 7 }
    end
    architecture_class = Class.new do
      const_set(:ENTRYPOINTS, { "fake.architecture" => "actions" }.freeze)
      define_method(:initialize) { |sink| @sink = sink }
      define_method(:call) { |**context| @sink << context; 8 }
    end
    original_patrol = Hive::Modules::Adapters::Patrol.method(:new)
    original_architecture = Hive::Modules::Adapters::ArchitecturePatrol.method(:new)
    Hive::Modules::Adapters::Patrol.define_singleton_method(:new) { patrol_class.new(calls) }
    Hive::Modules::Adapters::ArchitecturePatrol.define_singleton_method(:new) do
      architecture_class.new(calls)
    end
    begin
      assert Hive::Modules::FirstParty.load!
    ensure
      Hive::Modules::Adapters::Patrol.define_singleton_method(:new, original_patrol)
      Hive::Modules::Adapters::ArchitecturePatrol.define_singleton_method(:new, original_architecture)
    end

    assert_equal 7, Hive::Modules::Entrypoints.fetch("fake.patrol").call(project: "demo")
    assert_equal 8, Hive::Modules::Entrypoints.fetch("fake.architecture").call(project: "demo")
    assert_equal %w[actions scheduled-scan], calls.map { |context| context.fetch(:hook_id) }.sort
  end
end
