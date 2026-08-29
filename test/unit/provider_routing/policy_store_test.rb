require "test_helper"
require "hive/attempts/repository"
require "hive/provider_routing/policy_repository"

class ProviderRoutingPolicyRepositoryTest < Minitest::Test
  include HiveTestHelper

  def test_explicit_policy_round_trips_from_the_control_plane
    with_tmp_dir do |root|
      attempts = Hive::Attempts::Repository.new(root: root, migrate: true)
      policies = Hive::ProviderRouting::PolicyRepository.new(store: attempts)
      candidate = policy(model: "gpt-5.6-sol")

      stored = policies.fetch_or_store(
        ownership_generation: ownership_generation, subject: subject, policy: candidate
      )
      restarted = Hive::ProviderRouting::PolicyRepository.new(
        store: Hive::Attempts::Repository.new(root: root, migrate: true)
      )

      assert_equal candidate.to_h, stored.to_h
      assert_equal candidate.to_h, restarted.fetch_snapshot(
        ownership_generation: ownership_generation, subject: subject
      ).to_h
      assert_equal 1, attempts.database.read { |db| db[:routing_policies].count }
    end
  end

  def test_policy_is_first_writer_wins_for_one_ownership_subject
    with_policies do |policies, attempts|
      first = policy(model: "gpt-5.6-sol")
      changed = policy(model: "gpt-5.6-terra")

      winner = policies.fetch_or_store(
        ownership_generation: ownership_generation, subject: subject, policy: first
      )
      replay = policies.fetch_or_store(
        ownership_generation: ownership_generation, subject: subject, policy: changed
      )
      next_owner = policies.fetch_or_store(
        ownership_generation: "owner-2", subject: subject, policy: changed
      )

      assert_equal first.digest, winner.digest
      assert_equal first.digest, replay.digest
      assert_equal changed.digest, next_owner.digest
      assert_equal 2, attempts.database.read { |db| db[:routing_policies].count }
    end
  end

  def test_concurrent_writers_converge_on_one_policy
    with_policies do |policies, attempts|
      candidates = [ policy(model: "gpt-5.6-sol"), policy(model: "gpt-5.6-terra") ]
      gate = Queue.new
      writers = 6.times.map do |index|
        Thread.new do
          gate.pop
          policies.fetch_or_store(
            ownership_generation: ownership_generation, subject: subject,
            policy: candidates.fetch(index % candidates.length)
          ).digest
        end
      end
      6.times { gate << true }

      digests = writers.map(&:value)
      assert_equal 1, digests.uniq.length
      assert_includes candidates.map(&:digest), digests.first
      assert_equal 1, attempts.database.read { |db| db[:routing_policies].count }
    end
  end

  def test_malformed_or_mismatched_rows_fail_closed
    with_policies do |policies, attempts|
      candidate = policy(model: "gpt-5.6-sol")
      policies.fetch_or_store(
        ownership_generation: ownership_generation, subject: subject, policy: candidate
      )
      attempts.database.transaction do |db|
        db[:routing_policies].update(policy_json: "{")
      end

      assert_raises(Hive::ProviderRouting::PolicyRepository::InvalidSnapshot) do
        policies.fetch_snapshot(
          ownership_generation: ownership_generation, subject: subject
        )
      end
      assert_raises(Hive::ProviderRouting::PolicyRepository::InvalidSnapshot) do
        policies.fetch_or_store(
          ownership_generation: ownership_generation,
          subject: subject.merge("unsupported" => Object.new), policy: candidate
        )
      end
    end
  end

  def test_legacy_policy_bypasses_database_queries
    database = Object.new
    database.define_singleton_method(:read) { raise "database read" }
    database.define_singleton_method(:transaction) { raise "database transaction" }
    store = Struct.new(:database).new(database)
    policies = Hive::ProviderRouting::PolicyRepository.new(store: store)
    legacy = Hive::ProviderRouting::Policy.legacy(stage: "execute")

    assert_same legacy, policies.fetch(
      ownership_generation: Object.new, subject: Object.new, policy: legacy
    )
    assert_same legacy, policies.fetch_or_store(
      ownership_generation: Object.new, subject: Object.new, policy: legacy
    )
  end

  private

  def with_policies
    with_tmp_dir do |root|
      attempts = Hive::Attempts::Repository.new(root: root, migrate: true)
      yield Hive::ProviderRouting::PolicyRepository.new(store: attempts), attempts
    end
  end

  def ownership_generation = "opaque-owner:v7/alpha"

  def subject
    {
      "kind" => "task_stage", "task_id" => 42,
      "task_slug" => "durable-route-task", "intended_stage" => "4-execute"
    }
  end

  def policy(model:)
    route = Hive::ProviderRouting::Route.new(
      id: "codex-primary/#{model}", account: "codex-primary", adapter: "codex",
      launch_binding: "team-a", model: model, effort: "high", order: 0,
      capabilities: {
        "context" => "large", "quality" => "high",
        "tools" => %w[shell filesystem], "permissions" => %w[read write]
      }
    )
    Hive::ProviderRouting::Policy.explicit(
      stage: "execute", routes: [ route ],
      requirements: Hive::ProviderRouting::Requirements.new(
        context: "large", quality: "high", tools: [ "filesystem" ], permissions: [ "read" ]
      ),
      pin: Hive::ProviderRouting::Pin.new(provider: "codex-primary"),
      account_policy: {
        "codex-primary" => {
          "adapter" => "codex", "launch_binding" => "team-a",
          "models" => %w[gpt-5.6-sol gpt-5.6-terra], "max_concurrent" => 2,
          "cooldown_sec" => Hive::ProviderRouting::DEFAULT_COOLDOWN_SEC
        }
      }
    )
  end
end
