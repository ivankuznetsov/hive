require_relative "../../test_helper"
require "hive/provider_routing/operational_projection"

class ProviderRoutingOperationalProjectionTest < Minitest::Test
  NOW = Time.utc(2026, 8, 10, 12)

  class DecisionIndex
    def initialize(rows = []) = @rows = rows
    def routing_decisions(limit:) = @rows.first(limit)
  end

  AttemptStore = Data.define(:scan_result, :decision_index) do
    def scan = scan_result
  end

  def setup
    @root = Dir.mktmpdir("routing-operational-projection")
    @health = Hive::ProviderHealth::Store.new(root: File.join(@root, "health"), clock: -> { NOW })
    @attempts = AttemptStore.new(
      scan_result: Hive::Attempts::Scan.new(records: [].freeze, invalid_records: [].freeze),
      decision_index: DecisionIndex.new
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
end
