require "test_helper"
require "hive/patrol_fix/runner"
require "hive/stages/patrol_fix/inbox"
require "hive/stages/patrol_fix/runner"
require "hive/attempts/context"
require "hive/attempts/diagnostic_channel"
require "hive/github_publication"

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

  def test_controller_failures_publish_semantic_attempt_diagnostics_before_reraising
    cases = [
      [ "validate", Hive::StageError.new("validation changed the worktree bytes"),
        "validation_mutation" ],
      [ "publish", Hive::StageError.new("reviewed worktree is dirty before publication"),
        "fix_worktree_dirty" ],
      [ "publish", Hive::StageError.new("reviewed worktree HEAD changed before publication"),
        "worktree_head_custody_mismatch" ],
      [ "fix", Hive::StageError.new("fatal: unable to create .hive-state/index.lock"),
        "state_git_index_lock" ],
      [ "publish", Hive::GithubPublication::Blocked.new(
        "secret_detected", "publication secret policy blocked body bytes"
      ), "secret_policy_publish_blocked" ]
    ]

    cases.each do |stage, failure, expected_code|
      raised, frame = capture_controller_failure(stage: stage, failure: failure)

      assert_same failure, raised
      assert_equal "valid", frame.status
      assert_equal expected_code, frame.document.fetch("code")
      assert_equal "hive", frame.document.fetch("owner")
    end
  end

  def test_controller_failure_remains_authoritative_when_diagnostic_publication_also_fails
    failure = Hive::StageError.new("controller failed")

    raised = with_replaced_singleton_method(
      Hive::PatrolFix::Runner, :run!, ->(*) { raise failure }
    ) do
      with_replaced_singleton_method(
        Hive::Stages::ManagedAgentCustody,
        :publish_controller_failure,
        ->(**) { raise IOError, "diagnostic pipe closed" }
      ) do
        assert_raises(Hive::StageError) do
          Hive::Stages::PatrolFix::Runner.run!(Struct.new(:stage_name).new("fix"))
        end
      end
    end

    assert_same failure, raised
  end

  private

  def capture_controller_failure(stage:, failure:)
    reader, writer = IO.pipe
    context = Hive::Attempts::Context.send(
      :new,
      attempt_id: "attempt-controller", task_generation: 4,
      ownership_generation: "opaque-generation", intended_stage: stage_dir(stage),
      diagnostic_writer: Hive::Attempts::DiagnosticChannel::Writer.new(writer)
    )
    task = Struct.new(:stage_name).new(stage)
    transition = Object.new
    transition.define_singleton_method(:reconcile!) { nil }
    handler = ->(*) { raise failure }
    raised = nil

    with_replaced_singleton_method(Hive::Attempts::Context, :current, -> { context }) do
      with_replaced_singleton_method(Hive::PatrolFix::Transition, :new, ->(*) { transition }) do
        with_replaced_singleton_method(Hive::PatrolFix::Runner, :load_handler, ->(*) { handler }) do
          raised = assert_raises(failure.class) do
            Hive::Stages::PatrolFix::Runner.run!(task)
          end
        end
      end
    end
    context.close
    [ raised, Hive::Attempts::DiagnosticChannel.read(reader) ]
  ensure
    context&.close
    [ reader, writer ].compact.each do |io|
      io.close unless io.closed?
    rescue Errno::EBADF
      nil
    end
  end

  def stage_dir(stage)
    {
      "fix" => "2-fix", "validate" => "3-validate",
      "review" => "4-review", "publish" => "5-publish"
    }.fetch(stage)
  end
end
