require "test_helper"
require "hive/attempts/repository"
require "hive/provider_routing"

class AttemptsCoordinationTest < Minitest::Test
  include HiveTestHelper

  NOW = Time.utc(2026, 8, 10, 12)

  def test_replacement_attempt_is_independent_after_the_source_is_lost
    with_tmp_dir do |root|
      repository = Hive::Attempts::Repository.new(root: root, migrate: true)
      source = create(repository, attempt_id: "source", task_slug: "task")
      repository.mark_lost(source, reason: "worker_lost", now: NOW + 1)
      replacement = create(
        repository, attempt_id: "replacement", task_slug: "task",
        request_id: "request-replacement"
      )

      schema = repository.database.read { |db| db.schema(:attempts).map(&:first) }
      refute_includes schema, :predecessor_attempt_id
      refute_includes replacement.to_h, "predecessor_attempt_id"
      refute repository.respond_to?(:successor_attempt_id)
      refute repository.database.read { |db| db.table_exists?(:attempt_relationships) }
      repository.database.transaction do |db|
        db[:attempts].where(attempt_id: source.attempt_id).delete
      end
      assert_equal replacement.to_h, repository.fetch(replacement.attempt_id).to_h
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

      row = repository.database.read do |db|
        db[:attempts].where(attempt_id: lost.attempt_id).first
      end
      assert_equal "failed", row.fetch(:failure_cohort_outcome)
      assert_equal 1, row.fetch(:failure_cohort_counted)
      refute repository.database.read { |db| db.table_exists?(:attempt_failure_events) }
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
      successful = terminalize(repository, successor_probe, exit_status: 0)
      assert repository.record_failure_cohort_success(
        attempt_id: successful.attempt_id, date: NOW.to_date
      )
      refute repository.record_failure_cohort_success(
        attempt_id: successful.attempt_id, date: NOW.to_date
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
      missing_acceptance = terminal.with("accepted_at" => (NOW - 1).iso8601(6))
      assert_raises(Hive::Attempts::RepositoryError) do
        repository.send(:mark_refunded, missing_acceptance)
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
             failure_cohort_probe: nil)
    repository.create_launching(
      attempt_id: attempt_id, request_id: request_id.sub("1", attempt_id),
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
