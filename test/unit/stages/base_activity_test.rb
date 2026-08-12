require "test_helper"
require "hive/stages/base"

class HiveStagesBaseActivityTest < Minitest::Test
  include HiveTestHelper

  FakeWorkflow = Data.define(:id)
  FakeTask = Data.define(:folder, :slug, :id, :workflow)

  def test_stage_activity_uses_attempt_binding_and_stable_transition_ids
    task = FakeTask.new(
      folder: "/tmp/task", slug: "demo-task", id: "42",
      workflow: FakeWorkflow.new(id: "coding")
    )
    records = []
    fake = Object.new
    fake.define_singleton_method(:record) { |**attributes| records << attributes }
    constructors = []
    replacement = lambda do |**attributes|
      constructors << attributes
      fake
    end

    with_attempt_context(
      attempt_id: "attempt-1", task_generation: 3,
      ownership_generation: "owner-3"
    ) do
      context = Hive::Attempts::Context.current
      context.instance_variable_set(:@intended_stage, "4-execute")
      with_replaced_singleton_method(Hive::TaskActivity, :new, replacement) do
        assert Hive::Stages::Base.record_stage_activity(task, "4-execute", "entered")
        marker = Struct.new(:name).new(:execute_complete)
        assert Hive::Stages::Base.record_stage_activity(
          task, "4-execute", "exited", marker: marker
        )
      end
    end

    assert_equal 2, constructors.length
    assert_equal "attempt-1", constructors.first.fetch(:attempt_id)
    assert_equal 3, constructors.first.fetch(:task_generation)
    assert_equal %w[stage:attempt-1:enter stage:attempt-1:exit],
                 records.map { |record| record.fetch(:operation_id) }
    assert_equal %w[entered exited],
                 records.map { |record| record.dig(:payload, "transition") }
  end

  def test_stage_activity_is_unavailable_without_durable_context
    task = FakeTask.new(
      folder: "/tmp/task", slug: "demo-task", id: nil,
      workflow: FakeWorkflow.new(id: "coding")
    )

    refute Hive::Stages::Base.record_stage_activity(task, "4-execute", "entered")
  end
end
