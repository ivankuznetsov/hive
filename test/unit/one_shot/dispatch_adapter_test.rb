require "test_helper"
require "hive/one_shot/dispatch_adapter"

class OneShotDispatchAdapterTest < Minitest::Test
  NOW = Time.utc(2026, 9, 25, 10, 0, 0)

  Guard = Struct.new(:error) do
    def synchronize
      raise error if error

      yield
    end
  end

  class Runner
    attr_reader :ran, :closed

    def initialize(result: nil, error: nil)
      @result = result
      @error = error
      @ran = [ { "id" => "dispatch:attempt:a1", "action" => "hive run task", "outcome" => "failed" } ]
    end

    def call
      raise @error if @error

      @result
    end

    def close = @closed = true
  end

  def entry
    { "name" => "hive", "path" => "/tmp/hive", "hive_state_path" => "/tmp/hive/.hive-state" }
  end

  def test_success_wraps_runner_pass_and_closes_runtime
    runner = Runner.new(result: {
      ran: [], safe_to_stop: true,
      items: [ {
        "bucket" => "runnable_now", "id" => "dispatch:task:next",
        "component" => "dispatch", "reason" => "eligible",
        "next_check_at" => nil, "condition" => nil
      } ]
    })
    adapter = Hive::OneShot::DispatchAdapter.new(
      entry: entry, guard: Guard.new,
      runner_factory: -> { runner }, clock: -> { NOW }
    )

    result = adapter.call

    assert_equal "ok", result.to_h.fetch("status")
    assert_equal NOW.iso8601(6), result.to_h.fetch("next_due_at")
    assert result.safe_to_stop?
    assert runner.closed
  end

  def test_ownership_refusal_does_not_construct_runtime
    error = Hive::OneShot::ProjectGuard::OwnershipError.new(
      "daemon owns hive", code: "daemon_owned",
      owner: { "kind" => "daemon", "pid" => 42, "process_identity" => "7" }
    )
    built = false
    adapter = Hive::OneShot::DispatchAdapter.new(
      entry: entry, guard: Guard.new(error),
      runner_factory: -> { built = true }, clock: -> { NOW }
    )

    result = adapter.call

    assert_equal "refused", result.to_h.fetch("status")
    assert_equal "daemon_owned", result.to_h.dig("error", "code")
    refute built
  end

  def test_drain_failure_retains_completed_work_and_closes_runtime
    runner = Runner.new(error: RuntimeError.new("drain failed"))
    adapter = Hive::OneShot::DispatchAdapter.new(
      entry: entry, guard: Guard.new,
      runner_factory: -> { runner }, clock: -> { NOW }
    )

    result = adapter.call

    assert_equal "error", result.to_h.fetch("status")
    assert_equal "dispatch_failed", result.to_h.dig("error", "code")
    assert_equal runner.ran, result.to_h.fetch("ran")
    refute result.safe_to_stop?
    assert runner.closed
  end
end
