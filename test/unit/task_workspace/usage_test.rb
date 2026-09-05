require "test_helper"
require "bigdecimal"
require "hive/task_workspace/usage"

class TaskWorkspaceUsageTest < Minitest::Test
  NOW = Time.utc(2026, 9, 5, 12)

  def setup
    @previous = Hive::UsageDb.instance_variable_get(:@database)
    @directory = Dir.mktmpdir("hive-task-usage")
    @database = Hive::RuntimeControlPlane::Database.new(
      path: File.join(@directory, "runtime.sqlite3")
    ).migrate!
    Hive::UsageDb.database = @database
  end

  def teardown
    @database.disconnect
    Hive::UsageDb.database = @previous
    FileUtils.remove_entry(@directory)
  end

  def test_task_totals_survive_compaction_without_an_attempt_inventory
    record("a")
    record("b", input: 200)
    record("other", project_slug: "other", input: 999)
    before = usage.call
    assert_equal 350, before.dig("tokens", "input_output")
    assert_equal "complete", before["coverage"]
    assert_equal 2, before["sessions_count"]

    Hive::UsageDb.compact!(now: NOW)
    after = usage(attempts_panel: { "truncated" => true, "records" => [] }).call
    assert_equal before["tokens"], after["tokens"]
    assert_equal "complete", after["coverage"]
    assert_equal 2, after["compacted_sessions_count"]
    assert_empty after["sessions"]
    assert_equal 350, after.dig("model_totals", 0, "tokens", "input_output")
    assert_nil after.dig("api_equivalent", "subtotal_usd")
    assert_nil after.dig("api_equivalent", "observed_subtotal_usd")
    assert_includes after.dig("api_equivalent", "missing_dimensions"), "session_detail"
  end

  def test_recent_detail_is_bounded_but_totals_are_not
    record("a")
    record("b")
    result = usage(limits: Hive::TaskWorkspace::Limits.new(usage_sessions_per_attempt: 1)).call
    assert_equal 1, result["sessions"].length
    assert result["details_truncated"]
    assert_equal 250, result.dig("tokens", "input_output")
    assert_equal "complete", result["coverage"]
    assert_equal 2, result["sessions_count"]
  end

  def test_unknown_metrics_stay_partial_and_live_sessions_stay_pending
    record("unknown", input: nil)
    result = usage.call
    assert_equal "partial", result["coverage"]
    assert_equal 25, result.dig("tokens", "input_output")
    refute result.dig("tokens", "complete")
    assert_includes result.dig("tokens", "unavailable"), "input"
    Hive::UsageDb.compact!(now: NOW)
    assert_equal result["tokens"], usage.call["tokens"]
    record("live", started_at: NOW, ended_at: nil)
    assert_equal "pending", usage.call["coverage"]
  end

  def test_mixed_models_and_billing_routes_remain_distinct
    record("a", billing_route: "subscription")
    record("b", actual_model: "luna", billing_route: "api")
    Hive::UsageDb.compact!(now: NOW)
    result = usage.call
    assert_equal "mixed", result["billing_route"]
    assert_equal %w[luna sol], result["actual_models"]
    assert_equal [ "openai" ], result["actual_providers"]
    assert_equal [ 125, 125 ], result["model_totals"].map { |row| row.dig("tokens", "input_output") }
  end

  def test_rollup_keeps_known_subtotals_and_metered_session_counts
    record("known")
    record("unknown", input: nil)
    before = usage.call
    assert_equal 1, before["metered_sessions_count"]
    assert_equal 1, before["unmetered_sessions_count"]
    Hive::UsageDb.compact!(now: NOW)
    after = usage.call
    assert_equal before["tokens"], after["tokens"]
    assert_equal 1, after["metered_sessions_count"]
    assert_equal 1, after["unmetered_sessions_count"]
  end

  def test_missing_failed_and_expired_budget_reads_never_become_zero_totals
    assert_nil usage.call["tokens"]
    reader = Object.new
    reader.define_singleton_method(:task_usage) { |**| { available: false, reason: "store_missing" } }
    assert_equal "unavailable", usage(usage_reader: reader).call["coverage"]
    reader.define_singleton_method(:task_usage) { |**| raise IOError, "read failed" }
    assert_nil usage(usage_reader: reader).call["tokens"]

    clock = 0
    bounded = Hive::TaskWorkspace::BoundedUsageReader.new(
      reader: Hive::UsageDb, limits: Hive::TaskWorkspace::Limits.new,
      monotonic_clock: -> { clock }
    )
    clock = 100
    assert_equal "unavailable", usage(usage_reader: bounded).call["coverage"]
  end

  def test_task_reader_is_cached_and_scoped_independently_of_attempt_reads
    calls = 0
    reader = Object.new
    reader.define_singleton_method(:task_usage) do |**|
      calls += 1
      { available: true, sessions: [], groups: [], compacted_sessions_count: 0 }
    end
    bounded = Hive::TaskWorkspace::BoundedUsageReader.new(
      reader: reader, limits: Hive::TaskWorkspace::Limits.new
    )
    2.times { usage(usage_reader: bounded).call }
    assert_equal 1, calls
    bounded.task_usage(project_slug: "other", task_slug: "task")
    assert_equal 2, calls
  end

  def test_per_session_pricing_remains_separate_from_provider_reported_cost
    record("a", provider_reported_cost: 99)
    pricing = ->(_) do
      { coverage: "complete", subtotal_usd: BigDecimal("0.125"),
        missing_dimensions: [], rate_basis: nil }
    end
    result = usage(pricing: pricing).call
    assert_equal BigDecimal("0.125"), result.dig("api_equivalent", "subtotal_usd")
    assert_equal 99, result.dig("sessions", 0, "provider_reported_cost")

    pricing = Object.new
    pricing.define_singleton_method(:estimate) { |_| raise ArgumentError, "bad pricing" }
    result = usage(pricing: pricing).call
    assert_nil result.dig("api_equivalent", "subtotal_usd")
    assert_equal [ "pricing" ], result.dig("api_equivalent", "missing_dimensions")
    assert_equal 125, result.dig("tokens", "input_output")
  end

  def test_task_reader_bounds_an_over_returning_adapter
    reader = Object.new
    reader.define_singleton_method(:task_usage) do |**|
      { available: true, sessions: [ { id: "a" }, { id: "b" } ], groups: [] }
    end
    bounded = Hive::TaskWorkspace::BoundedUsageReader.new(
      reader: reader, limits: Hive::TaskWorkspace::Limits.new(usage_sessions_per_attempt: 1)
    )
    result = bounded.task_usage(project_slug: "demo", task_slug: "task")
    assert_equal [ { id: "a" } ], result[:sessions]
    assert result[:truncated]
  end

  def test_recent_session_keeps_optional_pricing_dimensions_from_its_receipt
    record("a", attempt_id: "attempt-a")
    dimensions = { "service_tier" => "priority" }
    received = nil
    pricing = lambda do |input|
      received = input[:pricing_dimensions]
      { coverage: "unavailable", missing_dimensions: [] }
    end
    result = usage(pricing: pricing, attempts_panel: {
      "records" => [ { "attempt_id" => "attempt-a", "sessions" => [
        { "session_id" => "a", "usage" => { "pricing_dimensions" => dimensions } }
      ] } ]
    }).call
    assert_equal dimensions, received
    assert_equal 125, result.dig("tokens", "input_output")
  end

  def test_bounded_reader_caps_rows_caches_attempts_and_fails_closed_at_deadline
    calls = 0
    now = 0.0
    reader = lambda do |**|
      calls += 1
      {
        available: true,
        sessions: [ usage_row("session-failed"), usage_row("extra-session") ],
        unattributed_count: 0
      }
    end
    limits = Hive::TaskWorkspace::Limits.new(
      usage_sessions_per_attempt: 1, usage_deadline_seconds: 2
    )
    bounded = Hive::TaskWorkspace::BoundedUsageReader.new(
      reader: reader, limits: limits, monotonic_clock: -> { now }
    )

    first = bounded.exact_attempt(attempt_id: "attempt-failed")
    second = bounded.exact_attempt(attempt_id: "attempt-failed")

    assert_equal 1, calls
    assert_equal 1, first.fetch(:sessions).length
    assert first.fetch(:truncated)
    assert_equal first, second

    now = 3.0
    expired = bounded.exact_attempt(attempt_id: "attempt-retry")
    refute expired.fetch(:available)
    assert_equal "deadline_exhausted", expired.fetch(:reason)
    assert_equal 1, calls
  end


  private

  def usage(**options)
    Hive::TaskWorkspace::Usage.new(project_slug: "hive", task_slug: "task", **options)
  end

  def usage_row(id)
    { session_id: id, input: 100, output: 25 }
  end

  def record(id, **overrides)
    started_at = NOW - 10 * 86_400
    Hive::UsageDb.record!(**{
      session_id: id, agent: "codex", model: "sol", actual_provider: "openai",
      actual_model: "sol", project_slug: "hive", task_slug: "task", stage: "4-execute",
      started_at: started_at, ended_at: started_at + 60,
      input: 100, output: 25, cached: 0
    }.merge(overrides))
  end
end
