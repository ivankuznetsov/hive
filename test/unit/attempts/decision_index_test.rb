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

  def test_patrol_retry_delay_is_per_task_and_survives_restart
    with_repository do |repository|
      attempt = create(repository, attempt_id: "failed", task_slug: "task")
      lost = repository.mark_lost(attempt, reason: "worker_lost", now: NOW + 3)
      restarted = Hive::Attempts::Repository.new(root: repository.root, database: repository.database)
      args = { task_generation: lost.task_generation, subject: lost.subject,
               runtime_digest: "a" * 64, now: NOW + 4 }
      expected = NOW + 3 + Hive::AgentLimit.retry_cooldown_sec
      assert_equal expected, restarted.patrol_retry_at(**args)
      assert_nil restarted.patrol_retry_at(**args.merge(now: expected))
      assert_nil restarted.patrol_retry_at(**args.merge(runtime_digest: "b" * 64))
      assert_nil restarted.patrol_retry_at(**args.merge(task_generation: "new-generation"))
      assert_nil restarted.patrol_retry_at(**args.merge(subject: lost.subject.merge("task_id" => "other")))
      refute repository.database.read { |db| db.table_exists?(:attempt_failure_cohorts) }
    end
  end

  def test_latest_success_releases_retry_delay_without_accounting
    with_repository do |repository|
      first = create(repository, attempt_id: "failed", task_slug: "task")
      terminalize(repository, first, exit_status: 1)
      args = { task_generation: first.task_generation, subject: first.subject,
               runtime_digest: "a" * 64, now: NOW + 4 }
      assert repository.patrol_retry_at(**args)
      second = create(repository, attempt_id: "success", task_slug: "task")
      terminalize(repository, second, exit_status: 0)
      assert_nil repository.patrol_retry_at(**args)
    end
  end

  def test_cancelled_patrol_attempt_waits_until_retry_deadline
    with_repository do |repository|
      attempt = create(repository, attempt_id: "cancelled", task_slug: "task")
      terminalize(repository, attempt, exit_status: 130, outcome: "cancelled")
      args = { task_generation: attempt.task_generation, subject: attempt.subject,
               runtime_digest: "a" * 64, now: NOW + 4 }
      deadline = NOW + 3 + Hive::AgentLimit.retry_cooldown_sec

      assert_equal deadline, repository.patrol_retry_at(**args)
      assert_nil repository.patrol_retry_at(**args.merge(now: deadline))
    end
  end

  def test_failure_without_patrol_admission_does_not_delay_patrol
    with_repository do |repository|
      attempt = create(repository, attempt_id: "ordinary", task_slug: "task", admission: nil)
      terminalize(repository, attempt, exit_status: 1)

      assert_nil repository.patrol_retry_at(
        task_generation: attempt.task_generation, subject: attempt.subject,
        runtime_digest: "a" * 64, now: NOW + 4
      )
    end
  end

  def test_coordination_rejects_invalid_accounting_routing_and_identity_inputs
    with_repository do |repository|
      assert_raises(Hive::Attempts::RepositoryError) { repository.terminal_attempt_id(request_id: "\n") }
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
    end
  end

  private

  def with_repository
    with_tmp_dir do |root|
      yield Hive::Attempts::Repository.new(root: root, migrate: true)
    end
  end

  def create(repository, attempt_id:, task_slug:, request_id: "request-1",
             admission: { "workflow" => "patrol_fix", "runtime_digest" => "a" * 64 })
    repository.create_launching(
      attempt_id: attempt_id, request_id: request_id.sub("1", attempt_id),
      task_id: task_slug, project: "demo", task_slug: task_slug,
      intended_stage: "4-execute", task_generation: "generation-#{task_slug}",
      ownership_generation: "owner-1", task_input_epoch: 1,
      progress_token: "progress-1", provider: "codex",
      worker_argv: [ "hive", "run", task_slug ],
      claim_capability_digest: Hive::Attempts::Capability.digest("c" * 64),
      starting_revision: nil, retry_charge: 0, inherited_outputs: [],
      admission: admission,
      launch_timeout_sec: 30, now: NOW
    )
  end

  def terminalize(repository, launching, exit_status:, outcome: exit_status.zero? ? "succeeded" : "failed")
    claimed = repository.claim(
      launching, owner: { "pid" => Process.pid }, claim_capability: "c" * 64,
      first_heartbeat_timeout_sec: 30, now: NOW + 1
    )
    running = repository.first_heartbeat(claimed, stale_sec: 30, now: NOW + 2)
    repository.terminalize(
      running, outcome: outcome, exit_status: exit_status,
      final_checkpoint: { "revision" => "a" * 40 }, output_references: [],
      log_reference: { "path" => "open/log", "size" => 0, "sha256" => "0" * 64 },
      now: NOW + 3
    )
  end
end
