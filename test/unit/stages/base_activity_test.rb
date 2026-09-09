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

    with_tmp_dir do |state_home|
      Hive::RuntimeControlPlane::Database.new(
        path: Hive::Paths.runtime_control_plane_path(state_home)
      ).migrate!.disconnect
      with_env("HIVE_HOME" => state_home) do
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

  def test_waiting_brainstorm_questions_are_recorded_from_a_bounded_read
    with_tmp_dir do |dir|
      state_file = File.join(dir, "brainstorm.md")
      File.write(state_file, <<~MARKDOWN)
        ## Round 1
        ### Q1. Which direction?
        ### A1.
        <!-- WAITING -->
      MARKDOWN
      task = Struct.new(:folder, :state_file, :stage_name).new(dir, state_file, "brainstorm")
      context = Struct.new(:attempt_id).new("attempt-1")
      records = []
      marker = Struct.new(:name).new(:waiting)

      with_replaced_singleton_method(Hive::Attempts::Context, :current, -> { context }) do
        with_replaced_singleton_method(
          Hive::Stages::Base, :record_task_activity,
          ->(*args, **kwargs) { records << [ args, kwargs ]; true }
        ) do
          assert Hive::Stages::Base.record_waiting_questions(task, "2-brainstorm", marker)
        end
      end

      assert_equal 1, records.length
      assert_equal "question_asked", records.first.last.fetch(:kind)
      assert_equal "Q1", records.first.last.dig(:payload, "question_id")
    end
  end

  def test_waiting_question_read_failure_is_non_fatal
    with_tmp_dir do |dir|
      task = Struct.new(:folder, :state_file, :stage_name).new(
        dir, File.join(dir, "missing.md"), "brainstorm"
      )
      context = Struct.new(:attempt_id).new("attempt-1")
      marker = Struct.new(:name).new(:waiting)
      with_replaced_singleton_method(Hive::Attempts::Context, :current, -> { context }) do
        refute Hive::Stages::Base.record_waiting_questions(task, "2-brainstorm", marker)
      end
    end
  end

  def test_subscription_profile_uses_a_budget_equivalent_guard
    profile = Struct.new(:billing_semantics, :budget_flag).new(:subscription_backed, nil)
    guards = Hive::Stages::Base.runtime_resource_guards(
      [], profile: profile, max_budget_usd: 10, timeout_sec: 30
    )

    assert_equal "budget_equivalent_guard", guards.first.fetch("kind")
    assert_equal "unenforced", guards.first.fetch("enforcement")

    api_profile = Struct.new(:billing_semantics, :budget_flag).new(:api_billed, "--budget")
    api_guards = Hive::Stages::Base.runtime_resource_guards(
      [], profile: api_profile, max_budget_usd: 10, timeout_sec: 30
    )
    assert_equal "monetary_api_cap", api_guards.first.fetch("kind")
    assert_equal "provider_cli", api_guards.first.fetch("enforcement")
  end
end
