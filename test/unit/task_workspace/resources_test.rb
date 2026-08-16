require "test_helper"
require "hive/task_workspace/resources"

class TaskWorkspaceResourcesTest < Minitest::Test
  def test_available_usage_without_attributed_sessions_is_missing_not_zero
    panel = Hive::TaskWorkspace::Resources.new(
      attempts_panel: attempts_panel(guards: []),
      usage_reader: ->(**) { { available: true, sessions: [], unattributed_count: 2 } }
    ).call

    usage = panel.fetch("records").find { |record| record["record_kind"] == "usage" }
    assert_equal "missing", usage.fetch("state")
    assert_nil usage.fetch("totals")
  end
  def test_subscription_budget_is_not_spend_and_unmatched_units_have_no_headroom
    usage = lambda do |attempt_id:, task_generation:, project_slug:, task_slug:|
      assert_equal "attempt-1", attempt_id
      assert_equal 3, task_generation
      assert_nil project_slug
      assert_nil task_slug
      {
        available: true,
        sessions: [
          { session_id: "session-1", input: 100, output: 50, cached: 10,
            model: "gpt", source: "runtime_receipt" }
        ],
        totals: { input: 100, output: 50, cached: 10 },
        unattributed: [], unattributed_count: 1
      }
    end
    panel = Hive::TaskWorkspace::Resources.new(
      attempts_panel: attempts_panel(
        guards: [ guard("budget_equivalent_guard", "usd", 50,
                        billing: "subscription_backed") ]
      ), usage_reader: usage
    ).call

    budget = panel.fetch("records").find { |row| row["record_kind"] == "guard" }
    assert_equal "Configured budget-equivalent guard", budget.fetch("label")
    refute_includes budget.fetch("label").downcase, "spend"
    assert_nil budget.fetch("headroom")
    usage_record = panel.fetch("records").find { |row| row["record_kind"] == "usage" }
    assert_equal 150, usage_record.dig("totals", "tokens")
    assert_equal 1, usage_record.fetch("unattributed_count")
  end

  def test_matching_token_observation_computes_headroom_and_exhaustion
    panel = Hive::TaskWorkspace::Resources.new(
      attempts_panel: attempts_panel(
        guards: [ guard("token_limit", "tokens", 100, observed: 105) ]
      ),
      usage_reader: ->(**) { { available: true, sessions: [], totals: { input: 0, output: 0, cached: 0 }, unattributed: [], unattributed_count: 0 } }
    ).call

    token = panel.fetch("records").find { |row| row["record_kind"] == "guard" }
    assert_equal "exhausted", token.fetch("state")
    assert_equal 0, token.fetch("headroom")
  end

  def test_retry_after_and_timeout_remain_different_resource_kinds
    panel = Hive::TaskWorkspace::Resources.new(
      attempts_panel: attempts_panel(
        guards: [
          guard("timeout", "seconds", 90),
          guard("account_quota", "requests", nil,
                retry_at: "2026-08-12T11:00:00Z")
        ]
      ),
      usage_reader: ->(**) { { available: false, sessions: [], totals: nil, unattributed: [], unattributed_count: nil } }
    ).call

    guards = panel.fetch("records").select { |row| row["record_kind"] == "guard" }
    assert_equal %w[account_quota timeout], guards.map { |row| row.fetch("kind") }.sort
    quota = guards.find { |row| row["kind"] == "account_quota" }
    assert_equal "retry-after", quota.fetch("state")
    usage = panel.fetch("records").find { |row| row["record_kind"] == "usage" }
    assert_equal "unavailable", usage.fetch("state")
    assert_nil usage.fetch("totals")
  end

  def test_duplicate_session_usage_is_counted_once
    reader = lambda do |**|
      row = { session_id: "session-1", input: 12, output: 4, cached: 2,
              model: "gpt", source: "runtime_receipt" }
      { available: true, sessions: [ row, row ], totals: { input: 24, output: 8, cached: 4 },
        unattributed: [], unattributed_count: 0 }
    end
    panel = Hive::TaskWorkspace::Resources.new(
      attempts_panel: attempts_panel(guards: []), usage_reader: reader
    ).call
    usage = panel.fetch("records").find { |row| row["record_kind"] == "usage" }

    assert_equal 1, usage.fetch("sessions").length
    assert_equal({ "input" => 12, "output" => 4, "cached" => 2, "tokens" => 16 },
                 usage.fetch("totals"))
  end

  def test_truncated_usage_rows_make_the_resource_panel_partial
    reader = lambda do |**|
      {
        available: true, truncated: true,
        sessions: [
          { session_id: "session-1", input: 12, output: 4, cached: 2,
            model: "gpt", source: "runtime_receipt" }
        ],
        unattributed_count: 0
      }
    end

    panel = Hive::TaskWorkspace::Resources.new(
      attempts_panel: attempts_panel(guards: []), usage_reader: reader
    ).call
    usage = panel.fetch("records").find { |row| row["record_kind"] == "usage" }

    assert_equal "partial", panel.fetch("state")
    assert_equal "partial", usage.fetch("state")
    assert usage.fetch("truncated")
  end

  def test_truncated_legacy_usage_is_partial_even_without_attributed_sessions
    panel = Hive::TaskWorkspace::Resources.new(
      attempts_panel: attempts_panel(guards: []),
      usage_reader: lambda do |**|
        {
          available: true, sessions: [], unattributed_count: 100,
          unattributed_truncated: true
        }
      end
    ).call
    usage = panel.fetch("records").find { |row| row["record_kind"] == "usage" }

    assert_equal "partial", panel.fetch("state")
    assert_equal "partial", usage.fetch("state")
    assert usage.fetch("unattributed_truncated")
    assert_includes panel.fetch("diagnostics").map { |row| row.fetch("reason") },
                    "usage_truncated"
  end

  private

  def attempts_panel(guards:)
    {
      "state" => "current", "diagnostics" => [], "truncated" => false,
      "records" => [
        {
          "attempt_id" => "attempt-1", "task_generation" => 3,
          "current" => true,
          "sessions" => [
            {
              "session_id" => "session-1", "guards" => guards,
              "resource_observation" => nil
            }
          ]
        }
      ]
    }
  end

  def guard(kind, unit, configured, observed: nil, billing: "not_applicable", retry_at: nil)
    {
      "kind" => kind, "unit" => unit, "scope" => "session",
      "source" => "workflow_descriptor", "enforcement" => "controller",
      "billing_semantics" => billing, "configured" => configured,
      "observed" => observed, "reset_at" => nil, "retry_at" => retry_at
    }
  end
end
