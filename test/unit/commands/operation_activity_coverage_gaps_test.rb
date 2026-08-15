require "test_helper"
require "hive/commands/answer"
require "hive/commands/approve"
require "hive/commands/decide"

class CommandOperationActivityCoverageGapsTest < Minitest::Test
  include HiveTestHelper

  class Operation
    attr_reader :completion

    def complete!(**payload)
      @completion = payload
    end
  end

  class Activity
    attr_reader :begin_payload, :results

    def initialize(receipts: [], error: nil)
      @receipts = receipts
      @error = error
      @operation = Operation.new
    end

    def begin_operation(**payload)
      @begin_payload = payload
      @operation
    end

    def reconcile_operations!
      raise @error if @error

      @results = @receipts.map { |receipt| yield receipt }
    end

    def operation = @operation
  end

  def test_answer_operations_begin_complete_and_reconcile_every_verdict
    command = Hive::Commands::Answer.new("task")
    binding = { "question_fingerprint" => "a" * 64 }
    activity = Activity.new
    command.instance_variable_set(:@answer_activity, activity)
    operation = command.send(:begin_answer_operation, Object.new, binding, 2, "Yes")
    assert_equal "answer_recorded", activity.begin_payload.fetch(:kind)
    command.send(:complete_answer_operation, operation, Object.new, binding, 2, "Yes")
    assert_equal "Q2", operation.completion.dig(:payload, "question_id")
    assert_equal binding.fetch("question_fingerprint"),
                 command.send(:answer_precondition, binding).fetch("question_fingerprint")
    assert_equal 64, command.send(:answer_postcondition, binding, "Yes").fetch("answer_fingerprint").length
    assert_equal command.send(:answer_fingerprint, " Yes "), command.send(:answer_fingerprint, "Yes")

    text = <<~MARKDOWN
      ## Round 1
      ### Q1. Answered?
      ### A1.
      yes
      ### Q2. Waiting?
      ### A2.
      <!-- WAITING -->
    MARKDOWN
    questions = Hive::BrainstormParser.parse_text(text)
    answered_value = {
      "question_fingerprint" => command.send(:question_fingerprint, questions[0]),
      "answer_fingerprint" => command.send(:answer_fingerprint, questions[0].answer)
    }
    answered = Hive::TaskActivity.fingerprint(answered_value)
    waiting = Hive::TaskActivity.fingerprint(
      "question_fingerprint" => command.send(:question_fingerprint, questions[1]),
      "answered" => false
    )
    receipts = [
      { "activity_kind" => "other", "source" => "command_service" },
      { "activity_kind" => "answer_recorded", "source" => "command_service",
        "expected_postcondition_fingerprint" => answered },
      { "activity_kind" => "answer_recorded", "source" => "command_service",
        "expected_postcondition_fingerprint" => "x", "precondition_fingerprint" => waiting },
      { "activity_kind" => "answer_recorded", "source" => "command_service",
        "expected_postcondition_fingerprint" => "x", "precondition_fingerprint" => "y" }
    ]
    activity = Activity.new(receipts: receipts)
    with_replaced_singleton_method(command, :read_brainstorm!, ->(*) { text }) do
      command.send(:reconcile_answer_operations, activity, Object.new)
    end
    assert_equal :defer, activity.results[0]
    assert_equal({ status: :committed, result: answered_value }, activity.results[1])
    assert_equal :not_committed, activity.results[2]
    assert_equal :ambiguous, activity.results[3]

    failing = Activity.new(error: Hive::TaskActivity::InvalidActivity.new("bad"))
    with_replaced_singleton_method(command, :read_brainstorm!, ->(*) { text }) do
      assert_nil command.send(:reconcile_answer_operations, failing, Object.new)
    end
  end

  def test_approval_operation_completion_and_reconciliation
    clock = -> { Time.utc(2026, 8, 12, 12) }
    command = Hive::Commands::Approve.new("task", clock: clock)
    operation = Operation.new
    command.send(:complete_approval_operation, operation, "/task", "3-plan", "forward")
    assert_equal "3-plan", operation.completion.dig(:result, "stage")

    state_file = nil
    with_tmp_dir do |root|
      state_file = File.join(root, "state.md")
      File.write(state_file, "<!-- WAITING -->\n")
      task = Struct.new(:stage_index, :stage_name, :state_file).new(2, "brainstorm", state_file)
      current = { "stage" => "2-brainstorm" }
      current_fingerprint = Hive::TaskActivity.fingerprint(current)
      precondition = Hive::TaskActivity.fingerprint(current.merge("marker" => "waiting"))
      receipts = [
        { "activity_kind" => "other", "source" => "command_service" },
        { "activity_kind" => "approval_recorded", "source" => "command_service",
          "expected_postcondition_fingerprint" => current_fingerprint },
        { "activity_kind" => "rejection_recorded", "source" => "command_service",
          "expected_postcondition_fingerprint" => "x", "precondition_fingerprint" => precondition },
        { "activity_kind" => "approval_recorded", "source" => "command_service",
          "expected_postcondition_fingerprint" => "x", "precondition_fingerprint" => "y" }
      ]
      activity = Activity.new(receipts: receipts)
      command.send(:reconcile_approval_operations, activity, task)
      assert_equal [ :defer, { status: :committed, result: current }, :not_committed, :ambiguous ],
                   activity.results

      failing = Activity.new(error: Hive::TaskActivity::InvalidActivity.new("bad"))
      assert_nil command.send(:reconcile_approval_operations, failing, task)
    end
    assert state_file
  end

  def test_decision_operations_and_current_fingerprints
    command = Hive::Commands::Decide.new("task", "approve", from: "approval")
    activity = Activity.new
    stage = Struct.new(:dir).new("3-approval")
    outcome = Struct.new(:name).new("approve")
    operation = command.send(:begin_decision_operation, activity, Object.new, stage, outcome, "a" * 16)
    assert_equal "decision_recorded", activity.begin_payload.fetch(:kind)

    task = Struct.new(:folder).new("/task")
    record = {
      "decision_id" => "a" * 16, "outcome" => "approve",
      "decided_at" => "2026-08-12T12:00:00Z", "to" => "4-publish"
    }
    command.send(:complete_decision_operation, operation, task, record)
    assert_equal "approve", operation.completion.dig(:payload, "decision")

    with_tmp_dir do |root|
      first = Struct.new(:dir, :state_file).new("3-approval", "approval.md")
      missing = Struct.new(:dir, :state_file).new("4-missing", "missing.md")
      invalid = Struct.new(:dir, :state_file).new("5-invalid", "invalid.md")
      File.write(File.join(root, first.state_file), <<~BODY)
        <!-- HIVE_DECISION_V1 {"decision_id":"#{'a' * 16}","outcome":"approve"} -->
        <!-- WAITING decision_id=#{'b' * 16} -->
      BODY
      File.symlink(File.join(root, "missing-target"), File.join(root, invalid.state_file))
      workflow = Struct.new(:stages).new([ first, missing, invalid ])
      task = Struct.new(:folder, :workflow).new(root, workflow)
      decisions, waiting = command.send(:current_decision_fingerprints, task)
      assert_equal 1, decisions.length
      assert_equal 1, waiting.length

      expected = decisions.first.fetch("fingerprint")
      precondition = waiting.first
      receipts = [
        { "activity_kind" => "other", "source" => "command_service" },
        { "activity_kind" => "decision_recorded", "source" => "command_service",
          "expected_postcondition_fingerprint" => expected },
        { "activity_kind" => "decision_recorded", "source" => "command_service",
          "expected_postcondition_fingerprint" => "x", "precondition_fingerprint" => precondition },
        { "activity_kind" => "decision_recorded", "source" => "command_service",
          "expected_postcondition_fingerprint" => "x", "precondition_fingerprint" => "y" }
      ]
      activity = Activity.new(receipts: receipts)
      command.send(:reconcile_decision_operations, activity, task)
      assert_equal :defer, activity.results[0]
      assert_equal :committed, activity.results[1].fetch(:status)
      assert_equal :not_committed, activity.results[2]
      assert_equal :ambiguous, activity.results[3]

      failing = Activity.new(error: Hive::TaskActivity::InvalidActivity.new("bad"))
      assert_nil command.send(:reconcile_decision_operations, failing, task)
    end
  end
end
