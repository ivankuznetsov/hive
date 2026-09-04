require_relative "../test_helper"
require "hive/attempts/dispatcher"
require "hive/attempts/evidence_channel"
require "hive/provider_routing"

class ProviderRoutingRecoveryTest < Minitest::Test
  include HiveTestHelper

  NOW = Time.utc(2026, 8, 10, 12)
  CAPABILITY = "c" * 64
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

  class RetryAdmissionView
    def initialize(store)
      @view = Hive::Attempts::AdmissionView.new(
        store: store, records: store.active_attempts
      )
    end

    def successor(**) = nil

    def method_missing(name, *args, **kwargs, &block)
      return super unless @view.respond_to?(name)

      @view.public_send(name, *args, **kwargs, &block)
    end

    def respond_to_missing?(name, include_private = false)
      @view.respond_to?(name, include_private) || super
    end
  end

  def setup
    @root = Dir.mktmpdir("provider-routing-recovery")
    @project_root = File.join(@root, "demo")
    @state_root = File.join(@project_root, ".hive-state")
    database = Hive::RuntimeControlPlane::Database.new(
      path: Hive::Paths.runtime_control_plane_path(@root)
    ).migrate!
    register_runtime_project(
      database: database, name: "demo", path: @project_root,
      state_root_path: @state_root
    )
    @store = Hive::Attempts::Repository.new(
      root: File.join(@root, "attempts"), database: database
    )
    @launcher = Launcher.new
    @ids = (1..20).map { |number| "attempt-#{number}" }.each
    @dispatcher = Hive::Attempts::Dispatcher.new(
      store: @store,
      launcher: @launcher,
      limits: { max_global: 20, max_per_project: 20, max_daily: 50 },
      clock: -> { NOW },
      id_generator: -> { @ids.next },
      decision_id_generator: -> { SecureRandom.uuid },
      capability_generator: -> { CAPABILITY }
    )
  end

  def teardown
    @store.database.disconnect
    FileUtils.remove_entry(@root)
  end

  def test_provider_failure_rotates_after_failed_route_and_wraps_once
    routed_task = task("rotate", 1)
    first = dispatch(routed_task, request_id: "initial", policy: policy)
    failed_a = terminalize_provider_failure(first)
    second = retry_after(failed_a, routed_task, request_id: "retry-b", policy: policy)
    failed_b = terminalize_provider_failure(second)
    third = retry_after(failed_b, routed_task, request_id: "retry-a", policy: policy)

    assert_equal "account-a/model-a", first.decision.route.id
    assert_equal "account-b/model-b", second.decision.route.id
    assert_equal "account-a/model-a", third.decision.route.id
  end

  def test_prior_provider_failure_does_not_change_unrelated_new_work
    routed_task = task("failed", 2)
    failed = terminalize_provider_failure(
      dispatch(routed_task, request_id: "failed-request", policy: policy)
    )
    unrelated = dispatch(task("unrelated", 3), request_id: "unrelated-request", policy: policy)

    assert_equal "account-a/model-a", failed["routing"].dig("route", "route_id")
    assert_equal "account-a/model-a", unrelated.decision.route.id
  end

  def test_retry_uses_current_configuration_when_failed_route_was_removed
    routed_task = task("removed", 4)
    failed = terminalize_provider_failure(
      dispatch(routed_task, request_id: "before-change", policy: policy)
    )
    current = policy(routes: [ route("account-b", "model-b", "claude", "binding-b", 0) ])

    retried = retry_after(failed, routed_task, request_id: "after-change", policy: current)

    assert_equal :accepted, retried.status
    assert_equal "account-b/model-b", retried.decision.route.id
    assert_equal %w[mode route], retried.attempt["routing"].keys.sort
  end

  private

  def dispatch(routed_task, request_id:, policy:)
    @dispatcher.dispatch(
      task: routed_task,
      project: "demo",
      intended_stage: "4-execute",
      argv: [ "hive", "run", routed_task.slug ],
      request_id: request_id,
      provider: "codex",
      routing_policy: policy,
      now: NOW
    )
  end

  def retry_after(predecessor, routed_task, request_id:, policy:)
    @dispatcher.dispatch_successor(
      predecessor: predecessor,
      task: routed_task,
      project: "demo",
      argv: [ "hive", "run", routed_task.slug ],
      request_id: request_id,
      provider: "codex",
      routing_policy: policy,
      admission_view: RetryAdmissionView.new(@store),
      now: NOW + 4
    )
  end

  def terminalize_provider_failure(result)
    capability = @launcher.launched.find do |record, _token|
      record.attempt_id == result.attempt.attempt_id
    end.fetch(1)
    claimed = @store.claim(
      result.attempt,
      owner: { "pid" => Process.pid },
      claim_capability: capability,
      first_heartbeat_timeout_sec: 30,
      now: NOW + 1
    )
    running = @store.first_heartbeat(claimed, stale_sec: 30, now: NOW + 2)
    reference = {
      "path" => "logs/#{running.attempt_id}.frames",
      "size" => 0,
      "sha256" => Digest::SHA256.hexdigest("")
    }
    route = running["routing"].fetch("route")
    signal = {
      "failure_class" => "account_quota",
      "scope" => {
        "kind" => "provider_account",
        "provider_account_id" => route.fetch("provider_account_id"),
        "model" => nil
      },
      "provenance" => "provider_diagnostic",
      "reset_hint_seconds" => nil
    }
    evidence = Hive::Attempts::EvidenceChannel.materialize(
      signal, record: running, source_reference: reference
    )
    @store.terminalize(
      running,
      outcome: "failed",
      exit_status: 70,
      final_checkpoint: running.checkpoint,
      output_references: [],
      log_reference: reference,
      provider_evidence: evidence,
      now: NOW + 3
    )
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

  def policy(routes: nil)
    routes ||= [
      route("account-a", "model-a", "codex", "binding-a", 0),
      route("account-b", "model-b", "claude", "binding-b", 1)
    ]
    accounts = routes.to_h do |candidate|
      [
        candidate.account,
        {
          "adapter" => candidate.adapter,
          "launch_binding" => candidate.launch_binding,
          "models" => [ candidate.model ],
          "max_concurrent" => 1
        }
      ]
    end
    Hive::ProviderRouting::Policy.explicit(
      stage: "execute",
      routes: routes,
      requirements: Hive::ProviderRouting::Requirements.empty,
      pin: nil,
      account_policy: accounts
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
      capabilities: {
        "context" => "large",
        "quality" => "high",
        "tools" => %w[shell],
        "permissions" => %w[read]
      }
    )
  end
end
