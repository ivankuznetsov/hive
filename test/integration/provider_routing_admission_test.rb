require_relative "../test_helper"
require "hive/attempts/dispatcher"
require "hive/provider_routing"

class ProviderRoutingAdmissionTest < Minitest::Test
  include HiveTestHelper

  NOW = Time.utc(2026, 8, 10, 12)
  CLAIM_CAPABILITY = "c" * 64
  FakeTask = Struct.new(
    :id, :slug, :folder, :state_file, :stage_index, :stage_name, :project_root,
    :worktree_path, :workflow, keyword_init: true
  )

  class Launcher
    attr_reader :launched

    def initialize
      @launched = []
    end

    def preflight! = true

    def launch(record, claim_capability:)
      @launched << [ record, claim_capability ]
      { "claimed" => true }
    end
  end

  def setup
    @root = Dir.mktmpdir("provider-routing-admission")
    @project_root = File.join(@root, "demo")
    @state_root = File.join(@project_root, ".hive-state")
    @database_path = File.join(@root, "runtime-control-plane.sqlite3")
    database = Hive::RuntimeControlPlane::Database.new(path: @database_path).migrate!
    register_runtime_project(
      database: database, name: "demo", path: @project_root,
      state_root_path: @state_root
    )
    @store = Hive::Attempts::Repository.new(
      root: File.join(@root, "attempts"), database: database
    )
    @launcher = Launcher.new
    @ids = (1..20).map { |number| "attempt-#{number}" }.each
    @decision_ids = (1..20).map { |number| "decision-#{number}" }.each
    @dispatcher = build_dispatcher
  end

  def teardown
    @store.database.disconnect
    FileUtils.remove_entry(@root)
  end

  def test_legacy_admission_does_not_construct_provider_state
    result = @dispatcher.dispatch(
      **dispatch_attributes(task("legacy", 1)),
      routing_policy: Hive::ProviderRouting::Policy.legacy(stage: "execute")
    )

    assert_equal :accepted, result.status
    assert_equal({ "mode" => "legacy" }, result.attempt["routing"])
    assert_equal "codex", result.attempt["provider"]
  end

  def test_selected_current_route_identity_is_committed_without_policy_health_or_decision_state
    result = dispatch(task("selected", 2), policy: policy)

    assert_equal :accepted, result.status
    assert result.decision.selected?
    assert_equal "account-a/model-a", result.decision.route.id
    assert_equal "codex", result.attempt["provider"]
    assert_equal %w[mode route], result.attempt["routing"].keys.sort
    assert_equal "account-a", result.attempt["routing"].dig("route", "provider_account_id")
    assert_equal "binding-a", result.attempt["routing"].dig("route", "launch_binding_id")
    assert_equal "subscription", result.attempt["routing"].dig("route", "billing_route")
    assert_equal "agent_profile_contract",
                 result.attempt["routing"].dig("route", "billing_evidence_source")
    refute @store.database.read { |db| db.table_exists?(:routing_policies) }
    refute @store.database.read { |db| db.table_exists?(:attempt_routing_decisions) }
    refute @store.database.read { |db| db.table_exists?(:provider_circuits) }
  end

  def test_provider_capacity_is_derived_from_live_attempts_in_configured_order
    first = dispatch(task("capacity-a", 3), policy: policy)
    second = dispatch(task("capacity-b", 4), policy: policy)
    saturated = dispatch(task("capacity-c", 5), policy: policy)

    assert_equal "account-a", first.attempt["routing"].dig("route", "provider_account_id")
    assert_equal "account-b", second.attempt["routing"].dig("route", "provider_account_id")
    assert_equal :deferred, saturated.status
    assert_equal "capacity_saturated", saturated.reason
    assert saturated.decision.capacity_saturated?
    assert_nil saturated.attempt
    assert_equal 2, @launcher.launched.length
  end

  def test_saturated_hard_pin_never_falls_through_to_another_provider
    pinned = policy(pin: Hive::ProviderRouting::Pin.new(provider: "account-a"))
    first = dispatch(task("pinned-a", 6), policy: pinned)
    blocked = dispatch(task("pinned-b", 7), policy: pinned)

    assert_equal :accepted, first.status
    assert_equal "account-a/model-a", first.decision.route.id
    assert_equal :no_route, blocked.status
    assert_equal "no_eligible_provider_route", blocked.reason
    assert_equal %w[provider_concurrency_saturated hard_pin_mismatch],
                 blocked.decision.exclusions.map(&:reason)
    assert_equal 1, @launcher.launched.length
  end

  def test_atomic_revalidation_prevents_concurrent_provider_over_admission
    single = policy(routes: [ route("account-a", "model-a", "codex", "binding-a", 0) ])
    tasks = [ task("race-a", 8), task("race-b", 9) ]
    second_database = Hive::RuntimeControlPlane::Database.new(path: @database_path).open!
    second_store = Hive::Attempts::Repository.new(
      root: File.join(@root, "attempts"), database: second_database
    )
    dispatchers = [
      build_dispatcher(
        store: @store, launcher: Launcher.new,
        id_generator: -> { "race-attempt-a" }
      ),
      build_dispatcher(
        store: second_store, launcher: Launcher.new,
        id_generator: -> { "race-attempt-b" }
      )
    ]
    ready = Queue.new
    release = Queue.new
    threads = dispatchers.each_with_index.map do |dispatcher, index|
      Thread.new do
        ready << true
        release.pop
        dispatcher.dispatch(
          **dispatch_attributes(tasks.fetch(index)), routing_policy: single
        )
      end
    end
    2.times { ready.pop }
    2.times { release << true }
    results = threads.map(&:value)
    live = @store.database.read do |db|
      db[:attempts].where(
        provider_account_id: "account-a", state: %w[launching running]
      ).count
    end

    assert_equal 1, results.count { |result| result.status == :accepted }
    assert_equal 1, live
  ensure
    second_database&.disconnect
  end

  private

  def build_dispatcher(store: @store, launcher: @launcher,
                       id_generator: -> { @ids.next })
    Hive::Attempts::Dispatcher.new(
      store: store,
      launcher: launcher,
      limits: { max_global: 20, max_per_project: 20, max_daily: 50 },
      clock: -> { NOW },
      id_generator: id_generator,
      decision_id_generator: -> { SecureRandom.uuid },
      capability_generator: -> { CLAIM_CAPABILITY }
    )
  end

  def dispatch(routed_task, policy:)
    @dispatcher.dispatch(
      **dispatch_attributes(routed_task), routing_policy: policy
    )
  end

  def dispatch_attributes(routed_task)
    {
      task: routed_task,
      project: "demo",
      intended_stage: "4-execute",
      argv: [ "hive", "run", routed_task.slug ],
      request_id: "request-#{routed_task.slug}",
      provider: "codex",
      now: NOW
    }
  end

  def task(slug, id)
    folder = File.join(@state_root, "stages", "4-execute", slug)
    FileUtils.mkdir_p(folder)
    state_file = File.join(folder, "task.md")
    File.write(state_file, "#{slug}\n<!-- WAITING -->\n")
    FakeTask.new(
      id: id,
      slug: slug,
      folder: folder,
      state_file: state_file,
      stage_index: 4,
      stage_name: "execute"
    )
  end

  def policy(routes: nil, pin: nil)
    routes ||= [
      route("account-a", "model-a", "codex", "binding-a", 0),
      route("account-b", "model-b", "claude", "binding-b", 1)
    ]
    account_policy = routes.map(&:account).uniq.to_h do |account_id|
      candidate = routes.find { |route| route.account == account_id }
      [ account_id, account(candidate.adapter, candidate.launch_binding, candidate.model) ]
    end
    Hive::ProviderRouting::Policy.explicit(
      stage: "execute",
      routes: routes,
      requirements: Hive::ProviderRouting::Requirements.empty,
      pin: pin,
      account_policy: account_policy
    )
  end

  def route(account_id, model, adapter, binding, order)
    Hive::ProviderRouting::Route.new(
      id: "#{account_id}/#{model}",
      account: account_id,
      adapter: adapter,
      launch_binding: binding,
      model: model,
      effort: "high",
      order: order,
      billing_route: "subscription",
      billing_evidence_source: "agent_profile_contract",
      capabilities: {
        "context" => "large", "quality" => "high",
        "tools" => %w[shell], "permissions" => %w[read]
      }
    )
  end

  def account(adapter, binding, model)
    {
      "adapter" => adapter,
      "launch_binding" => binding,
      "models" => [ model ],
      "max_concurrent" => 1
    }
  end
end
