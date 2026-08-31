require "test_helper"
require "hive/attempts/repository"
require "hive/provider_routing"

class AttemptsCoordinationTest < Minitest::Test
  include HiveTestHelper

  NOW = Time.utc(2026, 8, 10, 12)

  def test_routing_decision_round_trips_through_a_bounded_typed_query
    with_tmp_dir do |root|
      repository = Hive::Attempts::Repository.new(root: root, migrate: true)
      attempt = create(repository, attempt_id: "attempt-1", task_slug: "task")
      decision = selected_decision("decision-1")

      recorded = repository.record_routing_decision(
        decision: decision, task_generation: "generation-1", subject: subject,
        project: "demo", attempt_id: attempt.attempt_id
      )
      restarted = Hive::Attempts::Repository.new(root: root, migrate: true)

      assert_equal decision.to_h, recorded
      assert_equal decision.to_h,
                   restarted.routing_decision(task_generation: "generation-1", subject: subject)
      assert_equal attempt.attempt_id, restarted.routing_decisions.fetch(0).fetch("attempt_id")
      assert_raises(Hive::Attempts::RepositoryError) { restarted.routing_decisions(limit: 0) }
    end
  end

  def test_successor_identity_uses_one_relationship_row_not_a_duplicate_attempt_column
    with_tmp_dir do |root|
      repository = Hive::Attempts::Repository.new(root: root, migrate: true)
      predecessor = create(repository, attempt_id: "predecessor", task_slug: "task")
      repository.mark_lost(predecessor, reason: "worker_lost", now: NOW + 1)
      successor = create(
        repository, attempt_id: "successor", task_slug: "task",
        request_id: "request-successor", predecessor_attempt_id: predecessor.attempt_id
      )

      schema = repository.database.read { |db| db.schema(:attempts).map(&:first) }
      refute_includes schema, :predecessor_attempt_id
      assert_equal successor.attempt_id,
                   repository.successor_attempt_id(predecessor_attempt_id: predecessor.attempt_id)
      assert_equal 1, repository.database.read { |db| db[:attempt_relationships].count }
      assert_raises(Hive::Attempts::RepositoryError) do
        create(
          repository, attempt_id: "competing", task_slug: "task",
          request_id: "request-competing", predecessor_attempt_id: predecessor.attempt_id
        )
      end
    end
  end

  def test_failure_cohort_probe_is_claimed_with_attempt_creation_or_not_at_all
    with_repository do |repository|
      3.times do |index|
        attempt = create(repository, attempt_id: "failure-#{index}", task_slug: "task-#{index}")
        lost = repository.mark_lost(attempt, reason: "agent_failed", now: NOW + index)
        repository.record_failure_cohort(
          attempt_id: lost.attempt_id, identity: failure_identity,
          occurred_at: NOW + index
        )
      end
      probe_time = NOW + Hive::Attempts::Coordination::FAILURE_COHORT_COOLDOWN_SEC + 5
      attributes = {
        identity: failure_identity, date: NOW.to_date, now: probe_time,
        explicit_release: false
      }

      probe = create(
        repository, attempt_id: "probe-1", task_slug: "probe-1",
        failure_cohort_probe: attributes
      )
      assert_equal "blocked", repository.failure_cohort_admission(
        identity: failure_identity, date: NOW.to_date, now: probe_time
      ).fetch("status")
      assert_raises(Hive::Attempts::RepositoryError) do
        create(
          repository, attempt_id: "probe-2", task_slug: "probe-2",
          failure_cohort_probe: attributes
        )
      end
      assert_nil repository.fetch("probe-2")
      observed_probe = repository.database.read do |db|
        db[:attempt_failure_cohorts].get(:probe_attempt_id)
      end
      assert_equal probe.attempt_id, observed_probe
    end
  end

  def test_failure_events_are_idempotent_and_foreign_key_bound
    with_repository do |repository|
      attempt = create(repository, attempt_id: "failure", task_slug: "task")
      lost = repository.mark_lost(attempt, reason: "agent_failed", now: NOW)
      2.times do
        repository.record_failure_cohort(
          attempt_id: lost.attempt_id, identity: failure_identity, occurred_at: NOW
        )
      end

      assert_equal 1, repository.database.read { |db| db[:attempt_failure_events].count }
      assert_raises(Hive::Attempts::RepositoryError) do
        repository.record_failure_cohort(
          attempt_id: "missing", identity: failure_identity, occurred_at: NOW
        )
      end
    end
  end

  def test_failure_cohort_probe_failure_and_success_close_the_original_fence
    with_repository do |repository|
      3.times do |index|
        attempt = create(repository, attempt_id: "failure-#{index}", task_slug: "task-#{index}")
        lost = repository.mark_lost(attempt, reason: "agent_failed", now: NOW + index)
        repository.record_failure_cohort(
          attempt_id: lost.attempt_id, identity: failure_identity, occurred_at: NOW + index
        )
      end
      probe_time = NOW + Hive::Attempts::Coordination::FAILURE_COHORT_COOLDOWN_SEC + 5
      probe = create(
        repository, attempt_id: "probe", task_slug: "probe",
        failure_cohort_probe: {
          identity: failure_identity, date: NOW.to_date, now: probe_time,
          explicit_release: false
        }
      )
      lost_probe = repository.mark_lost(probe, reason: "agent_failed", now: probe_time + 1)
      different = failure_identity.merge("code" => "different_failure")

      assert repository.record_failure_cohort(
        attempt_id: lost_probe.attempt_id, identity: different, occurred_at: probe_time + 1
      )
      assert_equal "probe", repository.failure_cohort_admission(
        identity: failure_identity, date: NOW.to_date,
        now: probe_time + Hive::Attempts::Coordination::FAILURE_COHORT_COOLDOWN_SEC + 2
      ).fetch("status")

      successor_probe = create(
        repository, attempt_id: "success-probe", task_slug: "success-probe",
        failure_cohort_probe: {
          identity: failure_identity, date: NOW.to_date,
          now: probe_time + Hive::Attempts::Coordination::FAILURE_COHORT_COOLDOWN_SEC + 2,
          explicit_release: false
        }
      )
      assert repository.record_failure_cohort_success(
        attempt_id: successor_probe.attempt_id, date: NOW.to_date
      )
      refute repository.record_failure_cohort_success(
        attempt_id: successor_probe.attempt_id, date: NOW.to_date
      )
    end
  end

  def test_expired_probe_is_cleared_by_read_and_claim_paths
    with_repository do |repository|
      old_probe = create(repository, attempt_id: "old-probe", task_slug: "old-probe")
      digest = repository.send(:failure_cohort_digest, failure_identity)
      expired = (NOW - 1).iso8601(6)
      repository.database.transaction do |db|
        db[:attempt_failure_cohorts].insert(
          utc_date: NOW.to_date.iso8601, identity_digest: digest,
          identity_json: Hive::RuntimeControlPlane::Codec.dump_json(failure_identity),
          failure_count: 3, retry_at: (NOW - 2).iso8601(6),
          probe_attempt_id: old_probe.attempt_id, probe_expires_at: expired,
          updated_at: (NOW - 3).iso8601(6)
        )
      end

      row = repository.database.read do |db|
        db[:attempt_failure_cohorts].where(identity_digest: digest).first
      end
      assert_nil repository.send(:expire_probe, row, NOW).fetch(:probe_attempt_id)
      repository.database.transaction do |db|
        db[:attempt_failure_cohorts].where(identity_digest: digest).update(
          probe_attempt_id: old_probe.attempt_id, probe_expires_at: expired
        )
        refreshed = db[:attempt_failure_cohorts].where(identity_digest: digest).first
        assert_nil repository.send(:expire_probe, refreshed, NOW, db: db).fetch(:probe_attempt_id)
      end
    end
  end

  def test_coordination_rejects_invalid_accounting_routing_and_identity_inputs
    with_repository do |repository|
      launching = create(repository, attempt_id: "live", task_slug: "live")
      assert_raises(Hive::Attempts::RepositoryError) { repository.refund_unstarted(launching) }
      assert_raises(Hive::Attempts::RepositoryError) { repository.refund_tempfail(launching) }
      assert_raises(Hive::Attempts::RepositoryError) { repository.refund_tempfail(Object.new) }

      terminal = terminalize(repository, launching, exit_status: 0)
      assert_raises(Hive::Attempts::RepositoryError) { repository.refund_tempfail(terminal) }
      repository.database.transaction do |db|
        db[:attempt_accounting].where(attempt_id: terminal.attempt_id).delete
      end
      assert_raises(Hive::Attempts::RepositoryError) { repository.send(:mark_refunded, terminal) }

      assert_raises(Hive::Attempts::RepositoryError) do
        repository.record_routing_decision(
          decision: Object.new, task_generation: "generation-1",
          subject: subject, project: "demo"
        )
      end
      assert_raises(Hive::Attempts::RepositoryError) do
        repository.record_routing_decision(
          decision: selected_decision("wrong-generation"), task_generation: "other",
          subject: subject, project: "demo"
        )
      end
      assert_raises(Hive::Attempts::RepositoryError) do
        repository.record_routing_decision(
          decision: selected_decision("bad-subject"), task_generation: "generation-1",
          subject: Object.new, project: "demo"
        )
      end

      assert_raises(Hive::Attempts::RepositoryError) do
        repository.send(:live_admission, { "workflow" => "other" })
      end
      assert_raises(Hive::Attempts::RepositoryError) { repository.send(:live_admission, Object.new) }
      assert_raises(Hive::Attempts::RepositoryError) do
        repository.send(:failure_cohort_identity, failure_identity.except("code"))
      end
      assert_raises(Hive::Attempts::RepositoryError) do
        repository.send(:failure_cohort_identity, failure_identity.merge("runtime_digest" => "bad"))
      end
      assert_raises(Hive::Attempts::RepositoryError) do
        repository.send(:failure_cohort_identity, Object.new)
      end
      assert_raises(Hive::Attempts::RepositoryError) do
        repository.record_failure_cohort_success(attempt_id: "attempt", date: "not-a-date")
      end
      assert_raises(Hive::Attempts::RepositoryError) do
        repository.record_failure_cohort(
          attempt_id: "attempt", identity: failure_identity, occurred_at: "not-a-time"
        )
      end
      assert_raises(Hive::Attempts::RepositoryError) do
        repository.record_failure_cohort_success(attempt_id: "\n", date: NOW.to_date)
      end
    end
  end

  private

  def with_repository
    with_tmp_dir do |root|
      yield Hive::Attempts::Repository.new(root: root, migrate: true)
    end
  end

  def create(repository, attempt_id:, task_slug:, request_id: "request-1",
             predecessor_attempt_id: nil, failure_cohort_probe: nil)
    repository.create_launching(
      attempt_id: attempt_id, request_id: request_id.sub("1", attempt_id),
      predecessor_attempt_id: predecessor_attempt_id,
      task_id: task_slug, project: "demo", task_slug: task_slug,
      intended_stage: "4-execute", task_generation: "generation-#{task_slug}",
      ownership_generation: "owner-1", task_input_epoch: 1,
      progress_token: "progress-1", provider: "codex",
      worker_argv: [ "hive", "run", task_slug ],
      claim_capability_digest: Hive::Attempts::Capability.digest("c" * 64),
      starting_revision: nil, retry_charge: 0, inherited_outputs: [],
      failure_cohort_probe: failure_cohort_probe,
      launch_timeout_sec: 30, now: NOW
    )
  end

  def selected_decision(id)
    Hive::ProviderRouting::Decision.selected(
      request: request, route: route, considered: [ route ],
      decision_id: id, decided_at: NOW
    )
  end

  def request
    @request ||= Hive::ProviderRouting::Request.new(
      policy: policy, task_generation: "generation-1"
    )
  end

  def policy
    @policy ||= Hive::ProviderRouting::Policy.explicit(
      stage: "execute", routes: [ route ],
      requirements: Hive::ProviderRouting::Requirements.empty, pin: nil,
      account_policy: {
        "account-a" => {
          "adapter" => "codex", "launch_binding" => "default",
          "models" => [ "model-a" ], "max_concurrent" => 1,
          "cooldown_sec" => Hive::ProviderRouting::DEFAULT_COOLDOWN_SEC
        }
      }
    )
  end

  def route
    @route ||= Hive::ProviderRouting::Route.new(
      id: "account-a/model-a", account: "account-a", adapter: "codex",
      launch_binding: "default", model: "model-a", effort: "high", order: 0,
      capabilities: {
        "context" => "large", "quality" => "high", "tools" => %w[shell],
        "permissions" => %w[read]
      }
    )
  end

  def subject
    {
      "kind" => "task_stage", "task_id" => "task",
      "task_slug" => "task", "intended_stage" => "4-execute"
    }
  end

  def failure_identity
    {
      "runtime_digest" => "a" * 64, "project" => "demo",
      "workflow" => "patrol_fix", "stage" => "2-fix",
      "code" => "agent_exit_nonzero"
    }
  end

  def terminalize(repository, launching, exit_status:)
    claimed = repository.claim(
      launching, owner: { "pid" => Process.pid }, claim_capability: "c" * 64,
      first_heartbeat_timeout_sec: 30, now: NOW + 1
    )
    running = repository.first_heartbeat(claimed, stale_sec: 30, now: NOW + 2)
    repository.terminalize(
      running, outcome: exit_status.zero? ? "succeeded" : "failed", exit_status: exit_status,
      final_checkpoint: { "revision" => "a" * 40 }, output_references: [],
      log_reference: { "path" => "open/log", "size" => 0, "sha256" => "0" * 64 },
      now: NOW + 3
    )
  end
end
