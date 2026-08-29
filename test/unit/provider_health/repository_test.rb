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

  private

  def with_repository
    with_tmp_dir do |root|
      database = Hive::RuntimeControlPlane::Database.new(path: File.join(root, "runtime.sqlite3"))
      database.migrate!
      yield Hive::ProviderHealth::Repository.new(database: database, clock: -> { NOW })
    end
  end
end
