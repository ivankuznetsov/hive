require_relative "../../test_helper"
require "hive/provider_routing/operational_projection"

class ProviderRoutingOperationalProjectionTest < Minitest::Test
  include HiveTestHelper

  NOW = Time.utc(2026, 8, 10, 12)

  class DecisionQuery
    def initialize(rows = []) = @rows = rows
    def routing_decisions(limit:) = @rows.first(limit).freeze
  end

  AttemptStore = Data.define(:scan_result, :decision_query) do
    def scan = scan_result
    def live_reservations = {}
    def daily_counts(date:) = {}
    def routing_decisions(limit:) = decision_query.routing_decisions(limit: limit)
  end

  FakeRecord = Data.define(:attempt_id, :provider, :routing, :live) do
    def [](key) = key == "provider" ? provider : routing
    def explicit_routing? = routing.fetch("mode") == "explicit"
    def live? = live
  end

  def setup
    @root = Dir.mktmpdir("routing-operational-projection")
    @health = Hive::ProviderHealth::Store.new(root: File.join(@root, "health"), clock: -> { NOW })
    @attempts = AttemptStore.new(
      scan_result: Hive::Attempts::Scan.new(records: [].freeze, invalid_records: [].freeze),
      decision_query: DecisionQuery.new
    )
  end

  def teardown
    FileUtils.remove_entry(@root)
  end

  def test_projects_closed_scopes_capacity_and_sanitized_manual_state
    @health.block(
      scope: Hive::ProviderHealth::Scope.model(account_id: "account-a", model_id: "model-a"),
      expected_generation: 0,
      actor: "uid:1000",
      reason: "planned model maintenance"
    )

    payload = projection.to_h
    account = payload.fetch("accounts").first
    model = account.fetch("models").first.fetch("circuit")

    assert_equal "available", payload.fetch("status")
    assert_equal({ "observed" => 0, "max" => 2 }, account.fetch("capacity"))
    assert_equal "closed", account.dig("circuit", "state")
    assert_equal "manual_block", model.fetch("state")
    assert_equal 1, model.fetch("generation")
    assert_equal "planned model maintenance", model.dig("manual_block", "reason")
  end

  def test_empty_registry_structurally_bypasses_health_and_attempt_stores
    payload = Hive::ProviderRouting::OperationalProjection.new(
      accounts: {},
      health_store_factory: -> { flunk "health store must not open" },
      attempt_store_factory: -> { flunk "attempt store must not open" },
      now: NOW
    ).to_h

    assert_equal "not_configured", payload.fetch("status")
    assert_empty payload.fetch("accounts")
    assert_empty payload.fetch("decisions")
  end

  def test_invalid_registry_and_unavailable_stores_are_bounded_degraded_rows
    assert_raises(Hive::ConfigError) do
      Hive::ProviderRouting::OperationalProjection.new(accounts: { "bad" => Object.new })
    end

    failing_attempts = Object.new
    failing_attempts.define_singleton_method(:scan) do
      raise Hive::Attempts::RepositoryError, "unavailable"
    end
    failing_attempts.define_singleton_method(:live_reservations) do
      raise Hive::Attempts::RepositoryError, "unavailable"
    end
    failing_attempts.define_singleton_method(:routing_decisions) do |limit:|
      raise Hive::Attempts::RepositoryError, "unavailable" if limit
    end
    payload = Hive::ProviderRouting::OperationalProjection.new(
      accounts: { "account-a" => account }, attempt_store: failing_attempts,
      health_store: @health, now: NOW
    ).to_h
    assert_includes payload.fetch("issues"), "attempt_storage_unavailable"

    failing_health = Object.new
    failing_health.define_singleton_method(:inspect_scopes) do |_scopes, now:|
      raise Hive::ProviderHealth::Unavailable, "unavailable"
    end
    payload = Hive::ProviderRouting::OperationalProjection.new(
      accounts: { "account-a" => account }, attempt_store: @attempts,
      health_store: failing_health, now: NOW
    ).to_h
    row = payload.fetch("accounts").first
    assert_equal "health_state_unavailable", row.dig("circuit", "state")
    assert_equal "health_state_unavailable", row.dig("models", 0, "circuit", "state")
  end

  def test_capacity_fallback_counts_live_explicit_and_unambiguous_legacy_attempts
    records = [
      FakeRecord.new(
        "explicit", "codex",
        { "mode" => "explicit", "route" => { "provider_account_id" => "account-a" } },
        true
      ),
      FakeRecord.new("legacy", "codex", { "mode" => "legacy" }, true),
      FakeRecord.new("terminal", "codex", { "mode" => "legacy" }, false)
    ]
    attempts = AttemptStore.new(
      scan_result: Hive::Attempts::Scan.new(records: records, invalid_records: []),
      decision_query: DecisionQuery.new
    )
    with_replaced_singleton_method(
      Hive::Attempts::CapacitySnapshot, :build,
      ->(**) { raise Hive::Attempts::RepositoryError, "snapshot unavailable" }
    ) do
      payload = Hive::ProviderRouting::OperationalProjection.new(
        accounts: { "account-a" => account }, attempt_store: attempts,
        health_store: @health, now: NOW
      ).to_h
      assert_equal 2, payload.dig("accounts", 0, "capacity", "observed")
    end
  end

  def test_decision_projection_failure_is_reported_without_dropping_health
    index = Object.new
    index.define_singleton_method(:routing_decisions) do |limit:|
      raise Hive::Attempts::RepositoryError, "decision index unavailable" if limit
    end
    attempts = AttemptStore.new(
      scan_result: Hive::Attempts::Scan.new(records: [], invalid_records: []),
      decision_query: index
    )
    payload = Hive::ProviderRouting::OperationalProjection.new(
      accounts: { "account-a" => account }, attempt_store: attempts,
      health_store: @health, now: NOW
    ).to_h

    assert_includes payload.fetch("issues"), "routing_decisions_unavailable"
    assert_empty payload.fetch("decisions")
  end

  def test_decisions_are_filtered_to_the_projected_account_routes
    matching = decision_entry("account-a/model-a")
    unrelated = decision_entry("account-b/model-b")
    attempts = AttemptStore.new(
      scan_result: Hive::Attempts::Scan.new(records: [], invalid_records: []),
      decision_query: DecisionQuery.new([ matching, unrelated ])
    )

    payload = Hive::ProviderRouting::OperationalProjection.new(
      accounts: { "account-a" => account }, attempt_store: attempts,
      health_store: @health, now: NOW
    ).to_h

    assert_equal [ "account-a/model-a" ],
                 payload.fetch("decisions").map { |row| row.dig("decision", "selected_route") }
  end

  private

  def projection
    Hive::ProviderRouting::OperationalProjection.new(
      accounts: { "account-a" => account },
      health_store: @health,
      attempt_store: @attempts,
      now: NOW
    )
  end

  def account
    @account ||= Hive::ProviderRouting::Account.new(
      id: "account-a",
      adapter: "codex",
      launch_binding: "default",
      models: [ "model-a" ],
      max_concurrent: 2,
      cooldown_sec: Hive::ProviderRouting::DEFAULT_COOLDOWN_SEC
    )
  end

  def decision_entry(route_id)
    {
      "project" => "demo",
      "attempt_id" => "attempt-#{route_id}",
      "subject" => {
        "kind" => "task_stage", "task_id" => "task-1", "task_slug" => "task",
        "intended_stage" => "4-execute"
      },
      "decision" => {
        "selected_route" => route_id,
        "candidates" => [ { "route_id" => route_id } ]
      }
    }
  end
end
