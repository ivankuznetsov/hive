require "test_helper"
require "json"
require "hive/commands/patrol_fix_semantic_decision"

class HiveCommandsPatrolFixSemanticDecisionTest < Minitest::Test
  NOW = Time.utc(2026, 8, 21, 12)

  class Runtime
    attr_reader :calls

    def initialize(error: nil)
      @error = error
      @calls = []
    end

    def run_semantic_decision(**arguments)
      @calls << arguments
      raise @error if @error

      { "status" => "decided" }
    end
  end

  Retryable = Class.new(StandardError) do
    attr_reader :retry_at

    def initialize(retry_at)
      @retry_at = retry_at
      super("provider quota exhausted")
    end
  end

  def test_runs_one_exact_reservation_and_emits_a_bounded_success_envelope
    runtime = Runtime.new
    command = Hive::Commands::PatrolFixSemanticDecision.new(
      "demo", source: "ordinary_patrol", occurrence_id: "ordinary:finding-1:v1",
      reservation_id: "a" * 64, runtime: runtime, clock: -> { NOW }
    )

    out, = capture_io { assert_equal Hive::ExitCodes::SUCCESS, command.call }
    payload = JSON.parse(out)

    assert payload.fetch("ok")
    assert_equal "decided", payload.fetch("status")
    assert_equal({
      project: "demo", source_name: "ordinary_patrol",
      occurrence_id: "ordinary:finding-1:v1", reservation_id: "a" * 64,
      now: NOW
    }, runtime.calls.fetch(0))
  end

  def test_preserves_provider_retry_at_in_the_child_completion_envelope
    retry_at = NOW + 3_600
    runtime = Runtime.new(error: Retryable.new(retry_at))
    command = Hive::Commands::PatrolFixSemanticDecision.new(
      "demo", source: "architecture_patrol", occurrence_id: "architecture:job-1:item-1",
      reservation_id: "b" * 64, runtime: runtime, clock: -> { NOW }
    )

    out, = capture_io { assert_equal Hive::ExitCodes::TEMPFAIL, command.call }
    payload = JSON.parse(out)

    refute payload.fetch("ok")
    assert_equal retry_at.iso8601, payload.fetch("retry_at")
    assert_equal Retryable.name.to_s, payload.fetch("error_class")
  end
end
