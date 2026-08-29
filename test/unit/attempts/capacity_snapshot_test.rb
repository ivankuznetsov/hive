require "test_helper"
require "hive/attempts/capacity_snapshot"

class AttemptsCapacitySnapshotTest < Minitest::Test
  include HiveTestHelper

  NOW = Time.utc(2026, 8, 10, 12)

  def test_durable_reservations_are_the_capacity_authority
    with_repository do |repository|
      live = create(repository, attempt_id: "live", task_slug: "task-1")
      lost = create(repository, attempt_id: "lost", task_slug: "task-2")
      repository.mark_lost(lost, reason: "stale_generation", now: NOW + 1)

      snapshot = Hive::Attempts::CapacitySnapshot.build(store: repository, now: NOW)

      assert_equal 1, snapshot.global_count
      assert_equal [ live.attempt_id ], snapshot.reserved_attempt_ids
      assert_equal 1, snapshot.project_count("demo")
      assert snapshot.task_reserved?(project: "demo", task_slug: "task-1")
      refute snapshot.task_reserved?(project: "demo", task_slug: "task-2")
    end
  end

  def test_admission_view_refreshes_from_sql_without_repairing_indexes
    with_tmp_dir do |root|
      first = Hive::Attempts::Repository.new(root: root, migrate: true)
      view = Hive::Attempts::AdmissionView.new(store: first, hot_scan: first.scan)
      second = Hive::Attempts::Repository.new(root: root, migrate: true)
      created = create(second, attempt_id: "external", task_slug: "external")

      assert_empty view.refresh_for_admission
      assert_equal created.to_h, view.find(created.attempt_id).to_h
      assert_equal 1, view.capacity(now: NOW).global_count
    end
  end

  def test_daily_accounting_is_queryable_and_refunds_an_unstarted_loss
    with_repository do |repository|
      charged = create(repository, attempt_id: "charged", task_slug: "task-1")
      refundable = create(repository, attempt_id: "refundable", task_slug: "task-2")
      lost = repository.mark_lost(refundable, reason: "handoff_failed", now: NOW + 1)
      repository.refund_unstarted(lost)

      snapshot = Hive::Attempts::CapacitySnapshot.build(store: repository, now: NOW)
      assert_equal 1, snapshot.daily_count("demo", NOW.to_date)
      assert_equal false,
                   repository.daily_acceptances(date: NOW.to_date).fetch(charged.attempt_id).fetch("refunded")
      assert_equal true,
                   repository.daily_acceptances(date: NOW.to_date).fetch(lost.attempt_id).fetch("refunded")
    end
  end

  def test_capacity_limits_cover_host_project_task_and_daily_dimensions
    with_repository do |repository|
      create(repository, attempt_id: "live", task_slug: "task-1")
      snapshot = Hive::Attempts::CapacitySnapshot.build(store: repository, now: NOW)

      assert snapshot.at_limit?(
        project: "demo", task_slug: "task-2", date: NOW.to_date,
        max_global: 1, max_per_project: 2, max_daily: 10
      )
      assert snapshot.at_limit?(
        project: "demo", task_slug: "task-1", date: NOW.to_date,
        max_global: 2, max_per_project: 2, max_daily: 10
      )
      assert snapshot.at_limit?(
        project: "demo", task_slug: "task-2", date: NOW.to_date,
        max_global: 2, max_per_project: 1, max_daily: 10
      )
      assert snapshot.at_limit?(
        project: "demo", task_slug: "task-2", date: NOW.to_date,
        max_global: 2, max_per_project: 2, max_daily: 1
      )
    end
  end

  private

  def with_repository
    with_tmp_dir do |root|
      yield Hive::Attempts::Repository.new(root: root, migrate: true)
    end
  end

  def create(repository, attempt_id:, task_slug:)
    repository.create_launching(
      attempt_id: attempt_id, request_id: "request-#{attempt_id}",
      predecessor_attempt_id: nil, task_id: task_slug, project: "demo",
      task_slug: task_slug, intended_stage: "4-execute",
      task_generation: "generation-#{attempt_id}", ownership_generation: "owner-1",
      task_input_epoch: 1, progress_token: "progress-1", provider: "codex",
      worker_argv: [ "hive", "run", task_slug ],
      claim_capability_digest: Hive::Attempts::Capability.digest("c" * 64),
      starting_revision: "a" * 40, retry_charge: 0, inherited_outputs: [],
      launch_timeout_sec: 30, now: NOW
    )
  end
end
