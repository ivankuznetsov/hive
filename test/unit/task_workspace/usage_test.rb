require "test_helper"
require "bigdecimal"
require "net/http"
require "hive/task_workspace/usage"

class TaskWorkspaceUsageTest < Minitest::Test
  def test_failed_attempt_and_successful_retry_are_counted_once_per_durable_session
    pricing = ->(row) do
      {
        coverage: "complete", subtotal_usd: BigDecimal("0.125"),
        observed_subtotal_usd: nil, missing_dimensions: [],
        provider: row[:actual_backend], canonical_model: row[:actual_model],
        rate_basis: { source_url: "https://developers.openai.com/api/docs/models/gpt-5.6-sol" }
      }
    end
    duplicate = usage_row("session-failed", input: 100, output: 25)
    reader = lambda do |attempt_id:, **|
      sessions = attempt_id == "attempt-failed" ? [ duplicate, duplicate ] :
        [ usage_row("session-retry", input: 200, output: 50) ]
      { available: true, sessions: sessions, unattributed_count: 3 }
    end

    envelope = Hive::TaskWorkspace::Usage.new(
      attempts_panel: attempts_panel, usage_reader: reader, pricing: pricing
    ).call

    assert_equal "complete", envelope.fetch("coverage")
    assert_equal 2, envelope.fetch("sessions_count")
    assert_equal 375, envelope.dig("tokens", "input_output")
    assert_equal 3, envelope.fetch("unattributed_legacy_count")
    assert_equal BigDecimal("0.250"), envelope.dig("api_equivalent", "subtotal_usd")
    assert_nil envelope.dig("api_equivalent", "observed_subtotal_usd")
    assert_equal %w[failed succeeded], envelope.fetch("sessions").map { |row| row.fetch("outcome") }
    assert_equal %w[failed succeeded], envelope.fetch("groups").map { |row| row.fetch("outcome") }
  end

  def test_unmetered_live_and_truncated_inventories_cannot_look_complete
    attempts = attempts_panel
    attempts["truncated"] = true
    attempts["records"].last["sessions"] << session_binding(
      "session-live", outcome: nil, live: true
    )
    reader = lambda do |attempt_id:, **|
      rows = attempt_id == "attempt-failed" ? [] :
        [ usage_row("session-retry", input: 200, output: 50) ]
      { available: true, sessions: rows, unattributed_count: 0 }
    end

    envelope = Hive::TaskWorkspace::Usage.new(
      attempts_panel: attempts, usage_reader: reader, pricing: unavailable_pricing
    ).call

    assert_equal "pending", envelope.fetch("coverage")
    assert envelope.fetch("observed_subtotal")
    assert_equal 1, envelope.fetch("unmetered_sessions_count")
    assert_equal 1, envelope.fetch("live_sessions_count")
    assert_includes envelope.fetch("diagnostics").map { |row| row.fetch("reason") },
                    "attempt_inventory_truncated"
  end

  def test_usage_rows_without_a_durable_session_binding_are_excluded_and_reported
    reader = lambda do |attempt_id:, **|
      sessions = attempt_id == "attempt-failed" ?
        [ usage_row("session-failed"), usage_row("orphan-session") ] :
        [ usage_row("session-retry") ]
      { available: true, sessions: sessions, unattributed_count: 0 }
    end
    envelope = Hive::TaskWorkspace::Usage.new(
      attempts_panel: attempts_panel, usage_reader: reader, pricing: unavailable_pricing
    ).call

    assert_equal "partial", envelope.fetch("coverage")
    assert_equal 1, envelope.fetch("excluded_attributed_sessions_count")
    assert_equal 2, envelope.fetch("sessions_count")
  end

  def test_mixed_routes_keep_harness_provider_and_reported_cost_separate_from_observed_price
    sessions = [
      session_binding("session-subscription", outcome: "succeeded"),
      session_binding("session-api", outcome: "succeeded"),
      session_binding("session-unpriced", outcome: "failed")
    ]
    panel = {
      "state" => "current", "truncated" => false, "diagnostics" => [],
      "records" => [
        attempt("attempt-mixed", "failed", "unused").merge("sessions" => sessions)
      ]
    }
    reader = lambda do |**|
      dimensions = {
        "service_tier" => "standard", "context_tokens" => 1_000,
        "server_tool_usage" => "none"
      }
      common = {
        input: 100, output: 100, cache_read: 0, cache_write: 0, reasoning: 0,
        input_includes_cache_read: false, input_includes_cache_write: false,
        output_includes_reasoning: true, pricing_dimensions: dimensions,
        started_at: "2026-08-16T12:00:00Z"
      }
      {
        available: true, unattributed_count: 0,
        sessions: [
          common.merge(
            session_id: "session-subscription", harness: "codex",
            actual_backend: "openai", actual_model: "gpt-5.6-sol",
            billing_route: "subscription",
            billing_evidence_source: "agent_profile_contract"
          ),
          common.merge(
            session_id: "session-api", harness: "opencode",
            actual_backend: "openai", actual_model: "gpt-5.6-sol",
            billing_route: "api", billing_evidence_source: "provider_account_config",
            provider_reported_cost: BigDecimal("0.0001")
          ),
          common.merge(
            session_id: "session-unpriced", harness: "pi",
            actual_backend: "partner", actual_model: "partner-model",
            billing_route: "unknown", billing_evidence_source: "unavailable"
          )
        ]
      }
    end

    envelope = without_http do
      Hive::TaskWorkspace::Usage.new(
        attempts_panel: panel, usage_reader: reader
      ).call
    end

    assert_equal "partial", envelope.fetch("coverage")
    assert_equal "mixed", envelope.fetch("billing_route")
    assert_equal %w[codex opencode pi], envelope.fetch("harnesses")
    assert_equal [ "openai", "partner" ], envelope.fetch("actual_providers")
    assert_nil envelope.dig("api_equivalent", "subtotal_usd")
    assert_equal BigDecimal("0.007"), envelope.dig("api_equivalent", "observed_subtotal_usd")
    opencode = envelope.fetch("sessions").find { |row| row["harness"] == "opencode" }
    assert_equal "openai", opencode.fetch("actual_provider")
    assert_equal "api", opencode.fetch("billing_route")
    assert_equal BigDecimal("0.0001"), opencode.fetch("provider_reported_cost")
    assert_match(%r{developers\.openai\.com},
                 opencode.dig("api_equivalent", "rate_basis", :source_url))
  end

  private

  def without_http
    original = Net::HTTP.method(:start)
    Net::HTTP.define_singleton_method(:start) { |*| raise "network forbidden" }
    yield
  ensure
    Net::HTTP.define_singleton_method(:start, original)
  end

  def attempts_panel
    {
      "state" => "current", "truncated" => false, "diagnostics" => [],
      "records" => [
        attempt("attempt-failed", "failed", "session-failed"),
        attempt("attempt-retry", "succeeded", "session-retry")
      ]
    }
  end

  def attempt(id, outcome, session_id)
    {
      "attempt_id" => id, "task_generation" => 7,
      "project_slug" => "project", "task_slug" => "task",
      "stage" => "4-execute", "outcome" => outcome,
      "sessions" => [ session_binding(session_id, outcome: outcome) ]
    }
  end

  def session_binding(id, outcome:, live: false)
    {
      "session_id" => id, "outcome" => outcome, "live" => live,
      "provider" => "codex", "actual_model" => { "value" => "gpt-5.6-sol" }
    }
  end

  def usage_row(id, input: 10, output: 5)
    {
      session_id: id, harness: "codex", actual_backend: "openai",
      actual_model: "gpt-5.6-sol", billing_route: "subscription",
      billing_evidence_source: "agent_profile_contract",
      input: input, output: output, cache_read: 0, cache_write: 0, reasoning: 0,
      provider_reported_cost: BigDecimal("0.01"), started_at: "2026-08-16T12:00:00Z"
    }
  end

  def unavailable_pricing
    ->(_) do
      { coverage: "unavailable", subtotal_usd: nil, observed_subtotal_usd: nil,
        missing_dimensions: [ "model" ], provider: nil, canonical_model: nil,
        rate_basis: nil }
    end
  end
end
