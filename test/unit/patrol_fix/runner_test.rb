require "test_helper"
require "hive/patrol_fix/runner"

class PatrolFixRunnerTest < Minitest::Test
  include HiveTestHelper

  def test_load_handler_resolves_the_closed_first_party_stage_set
    expected = {
      "inbox" => :Inbox,
      "fix" => :Fix,
      "validate" => :Validate,
      "review" => :Review,
      "publish" => :Publish
    }

    expected.each do |stage, constant|
      handler = Hive::PatrolFix::Runner.send(:load_handler, stage)
      owner = Hive::Stages::PatrolFix.const_get(constant)
      assert_equal owner.method(:run!), handler
    end
    assert_nil Hive::PatrolFix::Runner.send(:load_handler, "done")
  end

  def test_run_reconciles_then_dispatches_without_a_mutable_registry
    task = Struct.new(:stage_name).new("inbox")
    calls = []
    transition = Object.new
    transition.define_singleton_method(:reconcile!) { calls << :reconcile }
    handler = lambda do |received_task, cfg, **kwargs|
      calls << [ received_task, cfg, kwargs ]
      { status: :complete }
    end

    received_tasks = []
    transition_factory = lambda do |received|
      received_tasks << received
      transition
    end
    result = with_replaced_singleton_method(
      Hive::PatrolFix::Transition, :new, transition_factory
    ) do
      with_replaced_singleton_method(Hive::Stages::PatrolFix::Inbox, :run!, handler) do
        Hive::PatrolFix::Runner.run!(task, nil, worktree_root: "/tmp/worktrees")
      end
    end

    assert_equal({ status: :complete }, result)
    assert_same task, received_tasks.fetch(0)
    assert_equal :reconcile, calls.fetch(0)
    assert_equal [ task, {}, { worktree_root: "/tmp/worktrees" } ], calls.fetch(1)
    refute_respond_to Hive::PatrolFix::Runner, :register
    refute_respond_to Hive::PatrolFix::Runner, :reset!
  end

  def test_unknown_stage_fails_closed
    task = Struct.new(:stage_name).new("done")
    transition = Object.new
    transition.define_singleton_method(:reconcile!) { nil }

    error = with_replaced_singleton_method(
      Hive::PatrolFix::Transition, :new, ->(*) { transition }
    ) do
      assert_raises(Hive::StageError) { Hive::PatrolFix::Runner.run!(task) }
    end

    assert_includes error.message, "controller for stage done is not available"
  end
end
