require "test_helper"
require "json"
require "hive/daemon/patrol_scheduler"

class HiveDaemonPatrolSchedulerTest < Minitest::Test
  include HiveTestHelper

  T0 = Time.utc(2026, 5, 28, 12, 0, 0)

  def setup
    @previous_usage_database = Hive::UsageDb.database
  end

  def teardown
    Hive::UsageDb.database = @previous_usage_database
  end

  class FakeGit
    attr_accessor :sha

    def initialize(sha: "new")
      @sha = sha
    end

    def default_branch(_project_root, cfg:)
      cfg["default_branch"] || "main"
    end

    def rev_parse(_project_root, _ref)
      @sha
    end
  end

  class CountingGit < FakeGit
    attr_reader :rev_parse_calls

    def initialize(sha: "new")
      super
      @rev_parse_calls = 0
    end

    def rev_parse(project_root, ref)
      @rev_parse_calls += 1
      super
    end
  end

  def project_entry(dir, name: "p1")
    {
      "name" => name,
      "path" => dir,
      "project_id" => "#{name}-id",
      "repository_identity" => "github.com/acme/#{name}",
      "hive_state_path" => File.join(dir, ".hive-state")
    }
  end

  def scheduler(entry, cfg, git: FakeGit.new)
    Hive::Daemon::PatrolScheduler.new(
      registry: -> { [ entry ] },
      config_loader: ->(_path) { cfg },
      git: git,
      database: runtime_database(entry)
    )
  end

  def runtime_database(entry)
    @runtime_databases ||= {}
    @runtime_databases[entry.fetch("path")] ||= begin
      database = prepare_runtime_project(
        state_home: tracked_tmp_dir("hive-test-patrol-runtime"),
        name: entry.fetch("name"), path: entry.fetch("path"),
        state_root_path: entry.fetch("hive_state_path"),
        project_id: entry.fetch("project_id")
      )
      (@hive_test_runtime_databases ||= []) << database
      Hive::UsageDb.database = database
      database
    end
  end

  def enabled_cfg(overrides = {})
    Hive::Config.deep_merge(
      Hive::Config.deep_dup(Hive::Config::DEFAULTS),
      {
        "default_branch" => "main",
        "patrol" => { "enabled" => true }
      }.merge(overrides)
    )
  end

  def write_state(project_root, data)
    dir = File.join(project_root, ".hive-state", "patrol")
    FileUtils.mkdir_p(dir)
    File.write(File.join(dir, "state.json"), JSON.pretty_generate(data))
  end

  def test_new_commit_reserves_patrol_once
    with_tmp_dir do |dir|
      write_state(dir, "last_scanned_sha" => "old")
      entry = project_entry(dir)
      scheduler = scheduler(entry, enabled_cfg)

      dispatches = scheduler.tick(now: T0)

      assert_equal 1, dispatches.size
      assert_equal "p1", dispatches.first[:project]
      assert_equal "patrol", dispatches.first[:slug]
      assert_equal "patrol", dispatches.first[:stage]
      assert_equal "hive patrol p1 --json", dispatches.first[:command]
      assert scheduler.pending?("p1")
      assert_empty scheduler.tick(now: T0 + 1),
                   "pending patrol child must not be re-dispatched"
    end
  end

  def test_unchanged_sha_is_not_due
    with_tmp_dir do |dir|
      cfg = enabled_cfg("patrol" => { "enabled" => true, "trigger" => "new_commits" })
      write_state(dir, "last_scanned_sha" => "same")
      git = FakeGit.new(sha: "same")
      assert_empty scheduler(project_entry(dir), cfg, git: git).tick(now: T0)
    end
  end

  def test_non_coding_default_workflow_is_ineligible_even_when_patrol_is_enabled
    with_tmp_dir do |dir|
      cfg = enabled_cfg("default_workflow" => "content")
      git = CountingGit.new

      assert_empty scheduler(project_entry(dir), cfg, git: git).candidates(now: T0)
      assert_equal 0, git.rev_parse_calls,
                   "an ineligible workflow must stop before repository inspection"
    end
  end

  def test_reservation_rechecks_non_coding_workflow_eligibility
    with_tmp_dir do |dir|
      entry = project_entry(dir)
      cfg = enabled_cfg
      sched = Hive::Daemon::PatrolScheduler.new(
        registry: -> { [ entry ] },
        config_loader: ->(_path) { cfg },
        git: FakeGit.new,
        database: runtime_database(entry)
      )
      candidate = sched.candidates(now: T0).fetch(0)
      cfg = enabled_cfg("default_workflow" => "content")

      assert_nil sched.reserve(candidate, now: T0)
      refute sched.pending?(entry.fetch("name"))
    end
  end

  def test_timer_mode_honors_interval
    with_tmp_dir do |dir|
      cfg = enabled_cfg("patrol" => {
        "enabled" => true,
        "trigger" => "timer",
        "poll_interval_sec" => 600
      })
      write_state(dir, "last_run_at" => (T0 - 599).utc.iso8601)
      sched = scheduler(project_entry(dir), cfg)

      assert_empty sched.tick(now: T0)

      write_state(dir, "last_run_at" => (T0 - 600).utc.iso8601)
      sched = scheduler(project_entry(dir), cfg)
      assert_equal 1, sched.tick(now: T0).size
    end
  end

  def test_timer_mode_rechecks_at_the_exact_due_time
    with_tmp_dir do |dir|
      cfg = enabled_cfg("patrol" => {
        "enabled" => true,
        "trigger" => "timer",
        "poll_interval_sec" => 600
      })
      write_state(dir, "last_run_at" => (T0 - 500).utc.iso8601)
      sched = scheduler(project_entry(dir), cfg)

      assert_empty sched.candidates(now: T0)
      assert_empty sched.candidates(now: T0 + 99)
      assert_equal 1, sched.candidates(now: T0 + 100).size
    end
  end

  def test_unselected_due_candidate_remains_eligible_for_the_next_tick
    with_tmp_dir do |dir|
      cfg = enabled_cfg("patrol" => {
        "enabled" => true,
        "trigger" => "timer",
        "poll_interval_sec" => 600
      })
      write_state(dir, "last_run_at" => (T0 - 600).utc.iso8601)
      sched = scheduler(project_entry(dir), cfg)

      assert_equal 1, sched.candidates(now: T0).size
      assert_equal 1, sched.candidates(now: T0 + 1).size
    end
  end

  def test_continuous_mode_dispatches_when_default_branch_changes_even_before_timer
    with_tmp_dir do |dir|
      cfg = enabled_cfg("patrol" => {
        "enabled" => true,
        "trigger" => "continuous",
        "poll_interval_sec" => 600
      })
      write_state(dir, "last_run_at" => (T0 - 599).utc.iso8601, "last_scanned_sha" => "old")
      git = FakeGit.new(sha: "new")

      dispatches = scheduler(project_entry(dir), cfg, git: git).tick(now: T0)

      assert_equal 1, dispatches.size
    end
  end

  def test_continuous_mode_dispatches_when_timer_elapses_without_new_commits
    with_tmp_dir do |dir|
      cfg = enabled_cfg("patrol" => {
        "enabled" => true,
        "trigger" => "continuous",
        "poll_interval_sec" => 600
      })
      write_state(dir, "last_run_at" => (T0 - 600).utc.iso8601, "last_scanned_sha" => "same")
      git = FakeGit.new(sha: "same")

      dispatches = scheduler(project_entry(dir), cfg, git: git).tick(now: T0)

      assert_equal 1, dispatches.size
    end
  end

  def test_continuous_mode_waits_when_timer_and_sha_are_unchanged
    with_tmp_dir do |dir|
      cfg = enabled_cfg("patrol" => {
        "enabled" => true,
        "trigger" => "continuous",
        "poll_interval_sec" => 600
      })
      write_state(dir, "last_run_at" => (T0 - 599).utc.iso8601, "last_scanned_sha" => "same")
      git = FakeGit.new(sha: "same")

      assert_empty scheduler(project_entry(dir), cfg, git: git).tick(now: T0)
    end
  end

  def test_disabled_project_never_dispatches
    with_tmp_dir do |dir|
      cfg = enabled_cfg("patrol" => { "enabled" => false })
      assert_empty scheduler(project_entry(dir), cfg).tick(now: T0)
    end
  end

  def test_complete_clears_pending_and_failure_backoff
    with_tmp_dir do |dir|
      write_state(dir, "last_scanned_sha" => "old")
      sched = scheduler(project_entry(dir), enabled_cfg)
      first = sched.tick(now: T0).fetch(0)
      assert_equal "hive patrol p1 --json", first.fetch(:command)

      sched.complete(project: "p1", exit_code: 1, now: T0 + 10)
      refute sched.pending?("p1")
      assert_empty sched.tick(now: T0 + 30),
                   "failed patrol should respect the first backoff interval"

      # A project with an outstanding failure retries on the backoff
      # cadence (60s), not the slow poll interval — the throttle is
      # exempt while a failure is recorded.
      retry_dispatch = sched.tick(now: T0 + 71).fetch(0)
      assert_equal "hive patrol p1 --json", retry_dispatch.fetch(:command)

      sched.complete(project: "p1", exit_code: 0, now: T0 + 80)
      refute sched.pending?("p1")
      # Success clears the failure backoff; the project is now governed by
      # the slow poll cadence (poll_interval_sec), so it does NOT
      # re-dispatch on the very next tick.
      assert_empty sched.tick(now: T0 + 81),
                   "after success the project waits the slow poll interval"
      assert_equal 1, sched.tick(now: T0 + 672).size,
                   "project is due again once poll_interval_sec elapses"
    end
  end

  def test_signal_exit_uses_failure_backoff
    with_tmp_dir do |dir|
      write_state(dir, "last_scanned_sha" => "old")
      sched = scheduler(project_entry(dir), enabled_cfg)
      assert_equal 1, sched.tick(now: T0).size

      sched.complete(project: "p1", exit_code: nil, now: T0 + 10)

      assert_empty sched.tick(now: T0 + 30),
                   "a signal-terminated patrol must not be recorded as success"
      assert_equal 1, sched.tick(now: T0 + 71).size,
                   "a signal-terminated patrol retries on failure backoff"
    end
  end

  def test_daily_launch_limit_defers_retry_until_the_next_utc_day
    with_tmp_dir do |dir|
      write_state(dir, "last_scanned_sha" => "old")
      sched = scheduler(project_entry(dir), enabled_cfg)
      assert_equal 1, sched.tick(now: T0).size
      envelope = {
        "review_errors" => [
          {
            "details" => {
              "resource_exhaustion" => {
                "reason" => "daily_agent_spawn_limit", "limit" => 8, "observed" => 8
              }
            }
          }
        ]
      }

      sched.complete(project: "p1", exit_code: 1, envelope: envelope, now: T0 + 10)

      assert_empty sched.tick(now: T0 + 43_199)
      assert_equal 1, sched.tick(now: T0 + 43_200).size
    end
  end

  def test_daily_launch_limit_skips_a_due_command_until_the_next_utc_day
    old_database = Hive::UsageDb.database
    with_tmp_dir do |dir|
      entry = project_entry(dir)
      database = runtime_database(entry)
      Hive::UsageDb.database = database
      budget = Hive::Patrol::LaunchBudget.new(
        dir, cfg: enabled_cfg, project_id: entry.fetch("project_id"),
        project_name: entry.fetch("name"), engine: :ordinary, database: database
      )
      4.times do |index|
        assert budget.acquire(
          profile: "codex", stage: "patrol-review", started_at: T0,
          reservation_id: "launch-#{index}"
        )
      end
      write_state(dir, "last_scanned_sha" => "old")
      sched = scheduler(entry, enabled_cfg)

      assert_empty sched.tick(now: T0)
      assert_equal T0 + 43_200,
                   sched.instance_variable_get(:@next_check_at).fetch("p1")
      assert_equal 1, sched.tick(now: T0 + 43_200).size
    end
  ensure
    Hive::UsageDb.database = old_database
  end

  def test_provider_retry_hold_survives_scheduler_restart_without_parking_architecture
    old_database = Hive::UsageDb.database
    with_tmp_dir do |dir|
      entry = project_entry(dir)
      Hive::UsageDb.database = runtime_database(entry)
      cfg = enabled_cfg
      write_state(dir, "last_scanned_sha" => "old")
      first = scheduler(entry, cfg)
      assert_equal 1, first.tick(now: T0).size
      retry_at = T0 + 3600
      first.complete(
        project: "p1", exit_code: 1, now: T0 + 10,
        envelope: {
          "review_errors" => [ {
            "details" => { "resource_exhaustion" => {
              "reason" => "provider_quota", "retry_at" => retry_at.iso8601
            } }
          } ]
        }
      )

      restarted = scheduler(entry, cfg)
      assert_empty restarted.tick(now: T0 + 20)
      architecture = Hive::Patrol::LaunchBudget.new(
        dir, cfg: cfg, project_id: entry.fetch("project_id"),
        project_name: entry.fetch("name"), engine: :architecture,
        database: runtime_database(entry),
        clock: -> { T0 + 20 }
      )
      assert_equal 4, architecture.remaining_launches
      assert_equal 1, restarted.tick(now: retry_at).size
    end
  ensure
    Hive::UsageDb.database = old_database
  end

  # Finding U2/poll_interval_sec: the new_commits trigger must run its
  # `git rev-parse` due-check on the slow patrol cadence, not every
  # daemon tick. Without the throttle the scheduler shelled out to git on
  # every ~30s tick.
  def test_new_commits_due_check_is_throttled_to_poll_interval
    with_tmp_dir do |dir|
      cfg = enabled_cfg("patrol" => { "enabled" => true, "trigger" => "new_commits" })
      write_state(dir, "last_scanned_sha" => "same")
      git = CountingGit.new(sha: "same")
      sched = scheduler(project_entry(dir), cfg, git: git)

      assert_empty sched.tick(now: T0)
      assert_equal 1, git.rev_parse_calls

      assert_empty sched.tick(now: T0 + 30)
      assert_equal 1, git.rev_parse_calls,
                   "git rev-parse must be throttled to poll_interval_sec, not run every tick"

      assert_empty sched.tick(now: T0 + 601)
      assert_equal 2, git.rev_parse_calls,
                   "git rev-parse runs again once the poll interval elapses"
    end
  end

  def test_scheduler_ignores_config_git_and_state_parse_errors
    with_tmp_dir do |dir|
      state_dir = File.join(dir, ".hive-state", "patrol")
      FileUtils.mkdir_p(state_dir)
      File.write(File.join(state_dir, "state.json"), "[")

      bad_git = Class.new(FakeGit) do
        def rev_parse(_project_root, _ref)
          raise Hive::GitError, "bad ref"
        end
      end.new

      assert_empty scheduler(project_entry(dir), enabled_cfg, git: bad_git).tick(now: T0)

      broken_loader = Hive::Daemon::PatrolScheduler.new(
        registry: -> { [ project_entry(dir) ] },
        config_loader: ->(_path) { raise Hive::ConfigError, "bad config" },
        git: FakeGit.new
      )
      assert_empty broken_loader.tick(now: T0)
    end
  end

  def test_git_helper_cancel_and_malformed_timer_paths
    with_tmp_git_repo do |repo|
      helper = Hive::Daemon::PatrolScheduler::GitHelper.new
      assert_equal "master", helper.default_branch(repo, cfg: { "default_branch" => "master" })
      assert_equal run!("git", "-C", repo, "rev-parse", "HEAD").strip,
                   helper.rev_parse(repo, "HEAD")
      assert_raises(Hive::GitError) { helper.rev_parse(repo, "does-not-exist") }
    end

    sched = Hive::Daemon::PatrolScheduler.new(registry: -> { [] })
    sched.instance_variable_set(:@pending, "p1" => { started_at: T0 })
    sched.instance_variable_set(:@next_check_at, "p1" => T0 + 600)
    sched.cancel(project: "p1")
    refute sched.pending?("p1")
    assert_empty sched.instance_variable_get(:@next_check_at)

    with_tmp_dir do |dir|
      cfg = enabled_cfg("patrol" => {
        "enabled" => true,
        "trigger" => "timer",
        "poll_interval_sec" => 600
      })
      write_state(dir, "last_run_at" => "not-time")
      assert_equal 1, scheduler(project_entry(dir), cfg).tick(now: T0).size
    end
  end

  def test_default_config_loader_is_used
    with_tmp_git_repo do |repo|
      FileUtils.mkdir_p(File.join(repo, ".hive-state"))
      cfg = enabled_cfg("project_name" => "p1")
      File.write(File.join(repo, ".hive-state", "config.yml"), cfg.to_yaml)
      write_state(repo, "last_scanned_sha" => "old")
      sched = Hive::Daemon::PatrolScheduler.new(
        registry: -> { [ project_entry(repo) ] },
        git: FakeGit.new(sha: "new"),
        database: runtime_database(project_entry(repo))
      )

      assert_equal 1, sched.tick(now: T0).size
    end
  end

  def test_completion_without_a_process_local_pending_marker_is_a_noop
    with_tmp_dir do |dir|
      sched = scheduler(project_entry(dir), enabled_cfg)

      sched.complete(
        project: "p1",
        exit_code: Hive::ExitCodes::SUCCESS,
        now: T0
      )

      refute sched.pending?("p1")
    end
  end

  def test_event_drain_reservation_failure_and_malformed_provider_retry_are_bounded
    with_tmp_dir do |dir|
      entry = project_entry(dir)
      sched = Hive::Daemon::PatrolScheduler.new(
        registry: -> { [] }, config_loader: ->(*) { enabled_cfg },
        state_store_factory: ->(*) { raise "store unavailable" }
      )
      sched.instance_variable_get(:@events) << { status: :blocked }
      assert_equal [ { status: :blocked } ], sched.drain_events
      assert_empty sched.drain_events

      candidate = { project: "p1", entry: entry, command: "hive patrol p1 --json" }
      assert_raises(RuntimeError) { sched.reserve(candidate, now: T0) }
      refute sched.pending?("p1")

      parks = []
      budget = Object.new
      budget.define_singleton_method(:park!) { |**values| parks << values }
      sched.define_singleton_method(:allowance_budget) { |*args, **kwargs| budget }
      sched.instance_variable_set(:@pending, "p1" => { entry: entry, started_at: T0 })
      sched.complete(
        project: "p1", exit_code: 1, now: T0,
        envelope: { "review_errors" => [ { "details" => { "resource_exhaustion" => {
          "reason" => "provider_quota", "retry_after_sec" => "invalid"
        } } } ] }
      )
      assert_equal T0 + 60, parks.fetch(0).fetch(:retry_at)
      assert_nil sched.send(:parse_retry_time, "not-a-time")
    end
  end
end
