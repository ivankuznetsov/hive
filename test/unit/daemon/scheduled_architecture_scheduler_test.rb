require "test_helper"
require "hive/daemon/scheduled_architecture_scheduler"

class HiveDaemonScheduledArchitectureSchedulerTest < Minitest::Test
  include HiveTestHelper
  NOW = Time.utc(2026, 9, 9, 12)

  def with_scheduler(dry_run: false)
    with_tmp_dir do |root|
      entry = { "name" => "demo", "path" => root, "project_id" => "demo-id",
                "hive_state_path" => File.join(root, ".hive-state") }
      cfg = Hive::Config.merge_defaults("daemon" => { "enabled" => true },
                                        "refactor_patrol" => { "enabled" => true },
                                        "patrol" => { "poll_interval_sec" => 60 })
      budget = Object.new
      budget.define_singleton_method(:remaining_launches) { 1 }
      subject = Hive::Daemon::ScheduledArchitectureScheduler.new(
        registry: -> { [ entry ] }, config_loader: ->(*) { cfg }, dry_run: dry_run
      )
      with_replaced_singleton_method(Hive::Patrol::LaunchBudget, :new, ->(*) { budget }) do
        yield subject, entry, cfg, budget
      end
    end
  end

  def test_dry_run_remains_eligible_after_cadence_without_child_completion
    with_scheduler(dry_run: true) do |subject, _entry, _cfg, _budget|
      candidate = subject.candidates(now: NOW).fetch(0)
      subject.reserve(candidate, now: NOW)
      assert_empty subject.candidates(now: NOW + 59)
      assert_equal 1, subject.candidates(now: NOW + 60).size
    end
  end

  def test_cancel_releases_pending_and_failure_backs_off_before_retry
    with_scheduler do |subject, _entry, _cfg, _budget|
      candidate = subject.candidates(now: NOW).fetch(0)
      dispatch = subject.reserve(candidate, now: NOW)
      assert_nil subject.reserve(candidate, now: NOW)
      assert_empty subject.candidates(now: NOW + 100)
      subject.cancel(dispatch, reason: "spawn_failed", now: NOW + 100)
      retry_candidate = subject.candidates(now: NOW + 100).fetch(0)
      dispatch = subject.reserve(retry_candidate, now: NOW + 100)
      result = subject.complete(dispatch_token: dispatch.fetch(:dispatch_token),
                                exit_code: 1, envelope: nil, now: NOW + 101)
      assert_equal :retry, result.fetch(:status)
      assert_empty subject.candidates(now: NOW + 160)
      assert_equal 1, subject.candidates(now: NOW + 161).size
    end
  end

  def test_restart_observes_last_run_and_reservation_rechecks_enabled_and_allowance
    with_scheduler do |subject, entry, cfg, budget|
      Hive::RefactorPatrol::StateStore.new(
        entry.fetch("path"), hive_state_path: entry.fetch("hive_state_path")
      ).update_state("last_run_at" => NOW.iso8601)
      assert_empty subject.candidates(now: NOW + 1)
      candidate = subject.candidates(now: NOW + 61).fetch(0)
      cfg["refactor_patrol"]["enabled"] = false
      assert_nil subject.reserve(candidate, now: NOW + 61)
      assert_empty subject.candidates(now: NOW + 61)
      cfg["refactor_patrol"]["enabled"] = true
      budget.define_singleton_method(:remaining_launches) { 0 }
      assert_nil subject.reserve(candidate, now: NOW + 61)
      assert_empty subject.candidates(now: NOW + 61)
    end
  end

  def test_invalid_state_reports_a_block_without_crashing_other_scheduler_work
    with_scheduler do |subject, entry, _cfg, _budget|
      Hive::RefactorPatrol::StateStore.new(
        entry.fetch("path"), hive_state_path: entry.fetch("hive_state_path")
      ).update_state("last_run_at" => "invalid")
      assert_empty subject.candidates(now: NOW)
      assert_equal "scheduled_discovery_unavailable", subject.drain_events.fetch(0).fetch(:reason)
      assert_empty subject.drain_events
    end
  end

  def test_empty_child_is_skipped_and_waits_a_full_interval_after_completion
    with_scheduler do |subject, _entry, _cfg, _budget|
      dispatch = subject.reserve(subject.candidates(now: NOW).fetch(0), now: NOW)
      result = subject.complete(dispatch_token: dispatch.fetch(:dispatch_token), exit_code: 0,
                                envelope: { "ok" => true, "reason" => "no_available_slice" }, now: NOW + 120)
      assert_equal :skipped, result.fetch(:status)
      assert_equal "no_available_slice", result.fetch(:reason)
      assert_empty subject.candidates(now: NOW + 179)
      assert_equal 1, subject.candidates(now: NOW + 180).size
    end
  end

  def test_real_daily_allowance_uses_tick_time_and_recovers_on_the_next_utc_day
    with_tmp_global_config do
      with_tmp_git_repo do |root|
        cfg = Hive::Config.merge_defaults(
          "daemon" => { "enabled" => true }, "refactor_patrol" => { "enabled" => true },
          "patrol" => { "mode" => "low" }
        )
        FileUtils.mkdir_p(File.join(root, ".hive-state"))
        File.write(File.join(root, ".hive-state", "config.yml"), cfg.to_yaml)
        Hive::Config.register_project(name: "demo", path: root)
        subject = Hive::Daemon::ScheduledArchitectureScheduler.new
        assert_equal [ "demo" ], subject.candidates(now: NOW).map { |item| item.fetch(:project) }
        limit = Hive::Config.load(root).dig("patrol", "scheduled_discovery_launches_per_engine_per_day")
        limit.times do |index|
          Hive::UsageDb.reserve_patrol_discovery!(
            session_id: "daily-architecture-#{index}", agent: "codex", project_slug: "demo",
            stage: "refactor-patrol-review", started_at: NOW, limit: limit
          )
        end
        assert_empty subject.candidates(now: NOW + 1)
        assert_equal [ "demo" ], subject.candidates(now: NOW + 86_400).map { |item| item.fetch(:project) }
      end
    end
  end
end
