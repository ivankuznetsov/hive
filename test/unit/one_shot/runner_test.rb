require "test_helper"
require "hive/one_shot/runner"

class OneShotRunnerTest < Minitest::Test
  NOW = Time.utc(2026, 9, 25, 11, 0, 0)

  class Dispatcher
    attr_reader :calls

    def initialize(error: nil)
      @error = error
      @calls = []
    end

    def run_one_shot(**options)
      @calls << [ :run, options ]
      raise @error if @error

      { ran: [ { "id" => "a", "action" => "run", "outcome" => "completed" } ],
        items: [], safe_to_stop: true }
    end

    def observe_one_shot(**options)
      @calls << [ :observe, options ]
      { ran: [], items: [], safe_to_stop: true }
    end

    def one_shot_ran
      [ { "id" => "a", "action" => "run", "outcome" => "failed" } ]
    end
  end

  def test_runs_one_admission_and_captures_result
    dispatcher = Dispatcher.new
    runner = Hive::OneShot::Runner.new(
      dispatcher: dispatcher, project: "hive", clock: -> { NOW }, sleeper: ->(_) {}
    )

    result = runner.call

    assert_equal :run, dispatcher.calls.fetch(0).fetch(0)
    assert_equal "completed", result.fetch(:ran).fetch(0).fetch("outcome")
    assert_equal result.fetch(:ran), runner.ran
  end

  def test_dry_run_only_observes
    dispatcher = Dispatcher.new
    runner = Hive::OneShot::Runner.new(
      dispatcher: dispatcher, project: "hive", dry_run: true, clock: -> { NOW }
    )

    assert_empty runner.call.fetch(:ran)
    assert_equal :observe, dispatcher.calls.fetch(0).fetch(0)
  end

  def test_failure_preserves_dispatcher_run_evidence
    dispatcher = Dispatcher.new(error: RuntimeError.new("failed"))
    runner = Hive::OneShot::Runner.new(
      dispatcher: dispatcher, project: "hive", clock: -> { NOW }
    )

    assert_raises(RuntimeError) { runner.call }
    assert_equal "failed", runner.ran.fetch(0).fetch("outcome")
  end
end
