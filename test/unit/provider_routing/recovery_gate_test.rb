require_relative "../../test_helper"
require "hive/provider_routing/recovery_gate"

class ProviderRoutingRecoveryGateTest < Minitest::Test
  include HiveTestHelper

  Row = Struct.new(:folder)
  Task = Struct.new(:stage_name, :stage_index, :slug)
  Decision = Struct.new(:selected, :explanation) do
    def selected? = selected
  end

  class FakeRouter
    attr_reader :requests, :cancelled

    def initialize(decisions)
      @decisions = decisions
      @requests = []
      @cancelled = []
    end

    def select(request)
      @requests << request
      @decisions.shift || Decision.new(false, "wait")
    end

    def cancel(decision, now:)
      @cancelled << [ decision, now ]
    end
  end

  NOW = Time.utc(2026, 7, 16, 12, 0, 0)

  def test_dispatchable_stage_route_is_selected_and_reservation_cancelled
    router = FakeRouter.new([ Decision.new(true, "claude selected") ])
    result = call_gate(task: Task.new("execute", 4, "slug"), config: base_config, router: router)

    assert result.dispatchable
    assert_equal "claude selected", result.explanation
    assert_equal 1, router.requests.length
    assert_equal 1, router.cancelled.length
  end

  def test_review_routes_are_all_considered_before_waiting
    config = base_config.merge(
      "review" => {
        "reviewers" => [ "ignored", { "agent" => "claude" } ],
        "ci" => { "agent" => "codex" }
      }
    )
    router = FakeRouter.new([ Decision.new(false, "wait"), Decision.new(false, "wait") ])
    result = call_gate(task: Task.new("review", 6, "slug"), config: config, router: router)

    refute result.dispatchable
    assert_equal "no configured route is currently dispatchable", result.explanation
    assert_equal %w[claude codex], router.requests.map { |request| request.configuration.pool.first.agent }
  end

  def test_review_without_role_entries_uses_legacy_claude_route
    router = FakeRouter.new([ Decision.new(false, "wait") ])
    result = call_gate(task: Task.new("review", 6, "slug"), config: base_config, router: router)

    refute result.dispatchable
    assert_equal "claude", router.requests.first.configuration.pool.first.agent

    fallback = Hive::ProviderRouting::RecoveryGate.new.send(:review_configurations, {})
    assert_equal "claude", fallback.first.pool.first.agent
  end

  def test_missing_hive_state_parent_returns_visible_failure
    gate = Hive::ProviderRouting::RecoveryGate.new
    result = gate.call(Row.new("/tmp/no-state/task"), now: NOW)

    refute result.dispatchable
    assert_includes result.explanation, "task path must match"
    error = assert_raises(Hive::ConfigError) do
      gate.send(:project_root_for, "/tmp/no-state/task")
    end
    assert_includes error.message, "could not locate .hive-state"
  end

  private

  def call_gate(task:, config:, router:)
    gate = Hive::ProviderRouting::RecoveryGate.new(router_factory: ->(_now) { router })
    with_replaced_singleton_method(Hive::Task, :new, ->(_folder) { task }) do
      with_replaced_singleton_method(Hive::Config, :load, ->(_root) { config }) do
        return gate.call(Row.new("/project/.hive-state/stages/4-execute/slug"), now: NOW)
      end
    end
  end

  def base_config
    Hive::Config.merge_defaults({})
  end
end
