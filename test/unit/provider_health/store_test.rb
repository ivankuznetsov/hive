require_relative "../../test_helper"
require "hive/provider_health/store"

class ProviderHealthStoreTest < Minitest::Test
  def setup
    @tmp = Dir.mktmpdir("provider-health-store")
    @root = File.join(@tmp, "provider-health", "v1")
    @attempts = {}
    @clock = Time.utc(2026, 8, 10, 12)
    @store = build_store
  end

  def teardown
    FileUtils.remove_entry(@tmp)
  end

  def test_evidence_open_is_idempotent_generation_fenced_and_restart_stable
    bind_attempt
    result = @store.apply_evidence(
      evidence: evidence(provider_scope),
      attempt: attempt,
      terminal_receipt: receipt,
      expected_generation: 0
    )
    duplicate = @store.apply_evidence(
      evidence: evidence(provider_scope),
      attempt: attempt,
      terminal_receipt: receipt,
      expected_generation: 0
    )

    assert result.accepted?
    assert_equal 1, result.generation
    assert duplicate.duplicate?
    assert_equal 1, duplicate.generation
    inspection = build_store.inspect_scope(provider_scope)
    assert_equal "open", inspection.circuit.automatic_state
    assert_equal result.current.to_h, inspection.circuit.to_h
    assert_equal 0o700, File.stat(@root).mode & 0o777
    state_directories.each { |path| assert_equal 0o700, File.stat(path).mode & 0o777 }
    state_files.each { |path| assert_equal 0o600, File.stat(path).mode & 0o777 }
  end

  def test_stale_and_fenced_evidence_are_bounded_nonmutating_audit_events
    bind_attempt
    stale = @store.apply_evidence(
      evidence: evidence(provider_scope),
      attempt: attempt,
      terminal_receipt: receipt,
      expected_generation: 4
    )
    fenced_attempt = build_attempt(ownership_fence: "stale-fence")
    fenced = @store.apply_evidence(
      evidence: evidence(model_scope, failure_class: "model_capacity"),
      attempt: fenced_attempt,
      terminal_receipt: receipt,
      expected_generation: 0
    )
    @attempts[attempt.attempt_id] = {
      "attempt_id" => attempt.attempt_id,
      "task_generation" => attempt.task_generation,
      "ownership_fence" => attempt.ownership_fence,
      "state" => "archived"
    }
    late = @store.apply_evidence(
      evidence: evidence(model_scope, failure_class: "model_capacity"),
      attempt: attempt,
      terminal_receipt: receipt.merge("terminal_lease_version" => 4),
      expected_generation: 0
    )

    assert_equal "rejected", stale.status
    assert_equal "stale_generation", stale.reason
    assert_equal 0, stale.generation
    assert_equal "rejected", fenced.status
    assert_equal "fenced_attempt", fenced.reason
    assert_equal 0, fenced.generation
    assert_equal "late_receipt", late.reason
    assert_equal 0, late.generation
    refute_includes all_state_bytes, "stale-fence"
  end

  def test_provider_and_model_composition_and_operator_actions_are_scope_safe
    bind_attempt
    @store.apply_evidence(
      evidence: evidence(model_scope, failure_class: "model_capacity"),
      attempt: attempt,
      terminal_receipt: receipt,
      expected_generation: 0
    )

    same_model = @store.evaluate_route(account_id: "codex-primary", model_id: "gpt-5.6-sol")
    sibling = @store.evaluate_route(account_id: "codex-primary", model_id: "gpt-5.6-terra")
    assert_equal [ "circuit_cooldown" ], same_model.blockers.map { |entry| entry.fetch("reason") }
    assert sibling.eligible?

    blocked = @store.block(
      scope: provider_scope,
      expected_generation: 0,
      actor: "uid:1000",
      reason: "planned maintenance"
    )
    unblocked = @store.unblock(
      scope: provider_scope,
      expected_generation: 1,
      actor: "uid:1000",
      reason: "maintenance complete"
    )
    reset_model = @store.reset(
      scope: model_scope,
      expected_generation: 1,
      actor: "uid:1000",
      reason: "verified provider recovery"
    )

    assert_equal 1, blocked.generation
    assert blocked.current.blocked?
    assert_equal 2, unblocked.generation
    refute unblocked.current.blocked?
    assert_equal "closed", reset_model.current.automatic_state
    assert_equal 2, reset_model.generation
    assert_equal 2, @store.inspect_scope(provider_scope).generation
  end

  def test_operator_generation_cas_serializes_concurrent_mutations_once
    gate = Queue.new
    results = 8.times.map do
      Thread.new do
        gate.pop
        begin
          @store.block(
            scope: provider_scope,
            expected_generation: 0,
            actor: "uid:1000",
            reason: "planned maintenance"
          ).status
        rescue Hive::ProviderHealth::StaleGeneration
          "stale"
        end
      end
    end
    8.times { gate << true }
    statuses = results.map(&:value)

    assert_equal 1, statuses.count("accepted")
    assert_equal 7, statuses.count("stale")
    assert_equal 1, @store.inspect_scope(provider_scope).generation
    assert_equal 1, journal_events(provider_scope).count { |event| event.fetch("kind") == "manual_blocked" }
  end

  def test_exact_model_reset_preserves_manual_block_until_explicit_unblock
    blocked = @store.block(
      scope: model_scope,
      expected_generation: 0,
      actor: "uid:1000",
      reason: "disable exact model route"
    )
    reset = @store.reset(
      scope: model_scope,
      expected_generation: 1,
      actor: "uid:1000",
      reason: "clear observed model health"
    )
    unblocked = @store.unblock(
      scope: model_scope,
      expected_generation: 2,
      actor: "uid:1000",
      reason: "restore exact model route"
    )

    assert blocked.current.blocked?
    assert reset.current.blocked?
    assert_equal "closed", reset.current.automatic_state
    refute unblocked.current.blocked?
    assert_equal 3, unblocked.generation
  end

  def test_secret_canaries_never_enter_state_audit_or_fingerprint
    bind_attempt
    unsafe_reference = reference.merge("message" => "secret-canary")
    assert_raises(Hive::ProviderHealth::InvalidEvidence) do
      evidence(provider_scope, source_reference: unsafe_reference)
    end
    assert_raises(Hive::ProviderHealth::InvalidMutation) do
      @store.block(
        scope: provider_scope,
        expected_generation: 0,
        actor: "uid:1000",
        reason: "api_key=secret-canary"
      )
    end

    @store.apply_evidence(
      evidence: evidence(provider_scope),
      attempt: attempt,
      terminal_receipt: receipt,
      expected_generation: 0
    )
    refute_includes all_state_bytes, "secret-canary"
  end

  private

  def build_store(**options)
    Hive::ProviderHealth::Store.new(
      root: @root,
      clock: -> { @clock },
      attempt_reader: ->(id) { @attempts[id] },
      **options
    )
  end

  def provider_scope
    @provider_scope ||= Hive::ProviderHealth::Scope.provider_account(account_id: "codex-primary")
  end

  def model_scope
    @model_scope ||= Hive::ProviderHealth::Scope.model(
      account_id: "codex-primary", model_id: "gpt-5.6-sol"
    )
  end

  def route
    @route ||= Hive::ProviderHealth::RouteIdentity.new(
      route_id: "codex-primary/gpt-5.6-sol",
      account_id: "codex-primary",
      adapter: "codex",
      launch_binding_id: "default",
      model_id: "gpt-5.6-sol"
    )
  end

  def attempt
    @attempt ||= build_attempt
  end

  def build_attempt(ownership_fence: "fence-1", probe_bindings: [])
    Hive::ProviderHealth::AttemptBinding.new(
      attempt_id: "attempt-1",
      task_generation: "task-generation-1",
      ownership_fence: ownership_fence,
      route: route,
      probe_bindings: probe_bindings
    )
  end

  def bind_attempt(value = attempt)
    @attempts[value.attempt_id] = value
  end

  def evidence(scope, failure_class: "provider_outage", source_reference: reference)
    Hive::ProviderHealth::Evidence.new(
      scope: scope,
      failure_class: failure_class,
      provenance: "codex_jsonl_transport",
      route: route,
      reset_hint_seconds: 300,
      source_reference: source_reference,
      attempt_id: "attempt-1"
    )
  end

  def reference
    { "path" => "outputs/safe.json", "size" => 12, "sha256" => "a" * 64 }
  end

  def receipt
    { "attempt_id" => "attempt-1", "receipt_version" => 1, "terminal_lease_version" => 3 }
  end

  def state_files
    Dir.glob(File.join(@root, "**", "*")).select { |path| File.file?(path) }
  end

  def state_directories
    Dir.glob(File.join(@root, "**", "*")).select { |path| File.directory?(path) }
  end

  def all_state_bytes
    state_files.map { |path| File.binread(path) }.join
  end

  def journal_events(scope)
    path = journal_file(scope)
    File.readlines(path).map { |line| JSON.parse(line) }
  end

  def journal_file(scope)
    kind = scope.provider_account? ? "provider-account" : "model"
    File.join(@root, "scopes", kind, scope.key, "journal.jsonl")
  end
end
