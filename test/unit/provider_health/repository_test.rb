require "test_helper"
require "hive/provider_health/repository"

class ProviderHealthRepositoryTest < Minitest::Test
  include HiveTestHelper

  NOW = Time.utc(2026, 8, 29, 12)

  def test_operator_mutations_are_generation_fenced_and_audited
    with_repository do |repository|
      scope = Hive::ProviderHealth::Scope.provider_account(account_id: "openai")
      inspection = repository.inspect_scope(scope)
      assert_equal "closed", inspection.circuit.automatic_state

      result = repository.block(
        scope: scope, expected_generation: 0, actor: "operator", reason: "maintenance"
      )
      assert result.accepted?
      assert_equal 1, result.generation
      assert_equal "manual_block", repository.inspect_scope(scope).circuit.effective_state(now: NOW)
      assert_raises(Hive::ProviderHealth::StaleGeneration) do
        repository.unblock(
          scope: scope, expected_generation: 0, actor: "operator", reason: "stale"
        )
      end
      unblocked = repository.unblock(
        scope: scope, expected_generation: 1, actor: "operator", reason: "ready"
      )
      assert_equal 2, unblocked.generation
      assert_equal 2, repository.database.read { |db| db[:provider_audit].count }
    end
  end

  def test_route_evaluation_reports_half_open_probe_from_circuit_rows
    with_repository do |repository|
      account = Hive::ProviderHealth::Scope.provider_account(account_id: "openai")
      repository.database.transaction do |db|
        db[:provider_circuits].insert(
          circuit_id: account.key, scope_kind: account.kind,
          provider_account_id: account.account_id, model: "",
          automatic_state: "open", manual_block: 0, generation: 4,
          journal_epoch: 0, eligible_at: (NOW - 1).iso8601(6),
          evidence_json: Hive::RuntimeControlPlane::Codec.dump_json("failure" => "quota"),
          updated_at: NOW.iso8601(6)
        )
      end
      evaluation = repository.evaluate_route(account_id: "openai", model_id: "gpt")
      assert evaluation.eligible?
      assert_equal [ account ], evaluation.probe_requirements.map(&:scope)
    end
  end

  def test_route_evaluation_preserves_open_and_cooldown_exclusions
    with_repository do |repository|
      account = Hive::ProviderHealth::Scope.provider_account(account_id: "openai")
      repository.database.transaction do |db|
        db[:provider_circuits].insert(
          circuit_id: account.key, scope_kind: account.kind,
          provider_account_id: account.account_id, model: "",
          automatic_state: "open", manual_block: 0, generation: 1,
          journal_epoch: 0, eligible_at: (NOW + 60).iso8601(6),
          evidence_json: Hive::RuntimeControlPlane::Codec.dump_json("failure" => "quota"),
          updated_at: NOW.iso8601(6)
        )
      end

      evaluation = repository.evaluate_route(account_id: "openai", model_id: "gpt")

      assert_equal "excluded", evaluation.status
      assert_equal %w[circuit_open circuit_cooldown],
                   evaluation.blockers.map { |item| item["reason"] }
    end
  end

  def test_read_failures_and_incomplete_routes_are_typed
    database = Object.new
    database.define_singleton_method(:read) do |&|
      raise Hive::RuntimeControlPlane::Unavailable.new("offline", code: :database_unavailable)
    end
    repository = Hive::ProviderHealth::Repository.new(database: database, clock: -> { NOW })
    assert_raises(Hive::ProviderHealth::Unavailable) do
      repository.inspect_scope(Hive::ProviderHealth::Scope.provider_account(account_id: "openai"))
    end
    assert_raises(Hive::ProviderHealth::Unavailable) do
      repository.evaluate_route(account_id: "openai", model_id: "gpt")
    end

    with_repository do |healthy|
      assert_raises(Hive::ProviderHealth::InvalidScope) do
        healthy.evaluate_routes(routes: [ { account_id: "openai" } ])
      end
    end
  end

  def test_invalid_mutations_and_stale_probe_requirements_fail_closed
    with_repository do |repository|
      scope = Hive::ProviderHealth::Scope.provider_account(account_id: "openai")
      assert_raises(Hive::ProviderHealth::InvalidMutation) do
        repository.apply_evidence(
          evidence: Object.new, attempt: Object.new, terminal_receipt: {}, expected_generation: 0
        )
      end
      assert_raises(Hive::ProviderHealth::InvalidMutation) do
        repository.complete_probe(attempt: Object.new, terminal_receipt: {}, outcome: "success")
      end
      repository.database.transaction do |db|
        assert_raises(Hive::ProviderHealth::InvalidMutation) do
          repository.claim_probe_bindings_in(
            db, requirements: [ Object.new ], attempt_id: "attempt-1",
            task_generation: "generation-1", ownership_fence: "owner-1", now: NOW
          )
        end
        stale = Hive::ProviderHealth::ProbeRequirement.new(
          scope: scope, journal_epoch: 0, observed_generation: 2
        )
        assert_raises(Hive::ProviderHealth::StaleGeneration) do
          repository.claim_probe_bindings_in(
            db, requirements: [ stale ], attempt_id: "attempt-1",
            task_generation: "generation-1", ownership_fence: "owner-1", now: NOW
          )
        end
      end
      assert_raises(Hive::ProviderHealth::StaleGeneration) do
        repository.block(
          scope: scope, expected_generation: "bad", actor: "operator", reason: "maintenance"
        )
      end
    end
  end

  def test_route_validation_rejects_an_ineligible_unchanged_circuit
    with_repository do |repository|
      scope = Hive::ProviderHealth::Scope.provider_account(account_id: "openai")
      blocked = repository.block(
        scope: scope, expected_generation: 0, actor: "operator", reason: "maintenance"
      )
      decision = Struct.new(:circuit_generations).new([
        {
          "scope" => scope.to_h, "observed_generation" => blocked.generation,
          "journal_epoch" => 0
        }
      ])
      repository.database.transaction do |db|
        assert_raises(Hive::ProviderHealth::StaleGeneration) do
          repository.validate_route_in(db, decision, now: NOW)
        end
      end
    end
  end

  def test_corrupt_circuit_rows_and_terminal_receipts_are_typed
    with_repository do |repository|
      scope = Hive::ProviderHealth::Scope.provider_account(account_id: "openai")
      repository.database.transaction do |db|
        db[:provider_circuits].insert(
          circuit_id: scope.key, scope_kind: scope.kind,
          provider_account_id: scope.account_id, model: "",
          automatic_state: "closed", manual_block: 0, generation: 0,
          journal_epoch: 0, evidence_json: "{", updated_at: NOW.iso8601(6)
        )
      end
      assert_raises(Hive::ProviderHealth::Unavailable) { repository.inspect_scope(scope) }

      assert_raises(Hive::ProviderHealth::InvalidMutation) do
        repository.complete_probe(
          attempt: attempt_binding, terminal_receipt: { "attempt_id" => "other" },
          outcome: "success"
        )
      end
    end
  end

  def test_invalid_expected_generation_is_recorded_as_a_stale_rejection
    with_repository do |repository|
      seed_attempt(repository.database)
      result = repository.apply_evidence(
        evidence: evidence, attempt: attempt_binding,
        terminal_receipt: terminal_receipt, expected_generation: "bad"
      )

      refute result.accepted?
      assert_equal "stale_generation", result.reason
    end
  end

  def test_invalid_cooldown_and_policy_lookup_fail_closed
    with_repository do |repository|
      seed_attempt(repository.database)
      repository.define_singleton_method(:cooldown_for) do |*, **|
        Hive::ProviderHealth::MAX_RESET_HINT_SECONDS + 1
      end
      assert_raises(Hive::ProviderHealth::InvalidMutation) do
        repository.apply_evidence(
          evidence: evidence, attempt: attempt_binding,
          terminal_receipt: terminal_receipt, expected_generation: 0
        )
      end
    end

    with_repository do |repository|
      seed_attempt(repository.database)
      failure = lambda do |**|
        raise Hive::ProviderRouting::PolicyRepository::InvalidSnapshot, "bad policy"
      end
      error = with_replaced_singleton_method(
        Hive::ProviderRouting::PolicyRepository, :new, failure
      ) do
        assert_raises(Hive::ProviderHealth::Unavailable) do
          repository.send(:cooldown_for, evidence, attempt_binding)
        end
      end
      assert_match(/provider cooldown policy is unavailable/, error.message)
    end
  end

  private

  def with_repository
    with_tmp_dir do |root|
      database = Hive::RuntimeControlPlane::Database.new(path: File.join(root, "runtime.sqlite3"))
      database.migrate!
      yield Hive::ProviderHealth::Repository.new(database: database, clock: -> { NOW })
    end
  end

  def route
    @route ||= Hive::ProviderHealth::RouteIdentity.new(
      route_id: "openai/gpt", account_id: "openai", adapter: "codex",
      launch_binding_id: "default", model_id: "gpt"
    )
  end

  def evidence
    Hive::ProviderHealth::Evidence.new(
      scope: Hive::ProviderHealth::Scope.provider_account(account_id: "openai"),
      failure_class: "provider_outage", provenance: "codex_jsonl_transport",
      route: route, reset_hint_seconds: 300,
      source_reference: { "path" => "outputs/safe.json", "size" => 1, "sha256" => "a" * 64 },
      attempt_id: "attempt-1"
    )
  end

  def attempt_binding
    Hive::ProviderHealth::AttemptBinding.new(
      attempt_id: "attempt-1", task_generation: "generation-1",
      ownership_fence: "owner-1", route: route, probe_bindings: []
    )
  end

  def terminal_receipt
    { "attempt_id" => "attempt-1", "receipt_version" => 1, "terminal_lease_version" => 1 }
  end

  def seed_attempt(database)
    timestamp = NOW.iso8601(6)
    document = Hive::RuntimeControlPlane::Codec.dump_json("attempt_id" => "attempt-1")
    database.transaction do |db|
      installation = db[:installations].get(:installation_id)
      db[:projects].insert_conflict.insert(
        project_id: "health-project", installation_id: installation,
        registration_id: "health-project", name: "health", observed_path: "/tmp/health",
        state_root_path: "/tmp/health/.hive-state", active: 1,
        registered_at: timestamp, last_observed_at: timestamp
      )
      db[:attempts].insert(
        attempt_id: "attempt-1", project_id: "health-project", task_id: nil,
        subject_kind: "module_hook", subject_key: "health",
        task_generation: "generation-1", ownership_generation: "owner-1",
        state: "terminal", outcome: "failed", lease_version: 1,
        routing_json: "{}", source_fingerprint: "source",
        record_json: document, record_digest: Digest::SHA256.hexdigest(document),
        subject_json: "{}", project_name: "health", task_slug: "health-task",
        accepted_date: "2026-08-29", created_at: timestamp,
        accepted_at: timestamp, ended_at: timestamp
      )
    end
  end
end
