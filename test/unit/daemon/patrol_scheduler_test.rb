require "test_helper"
require "json"
require "hive/daemon/patrol_scheduler"

class HiveDaemonPatrolSchedulerTest < Minitest::Test
  include HiveTestHelper

  T0 = Time.utc(2026, 5, 28, 12, 0, 0)

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
      "hive_state_path" => File.join(dir, ".hive-state")
    }
  end

  def scheduler(entry, cfg, git: FakeGit.new)
    Hive::Daemon::PatrolScheduler.new(
      registry: -> { [ entry ] },
      config_loader: ->(_path) { cfg },
      git: git
    )
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

  def test_new_commit_reserves_patrol_once_without_projecting_early_evidence
    with_tmp_dir do |dir|
      write_state(dir, "last_scanned_sha" => "old")
      entry = project_entry(dir)
      scheduler = scheduler(entry, enabled_cfg)

      dispatches = scheduler.tick(now: T0)

      assert_equal 1, dispatches.size
      assert_equal "p1", dispatches.first[:project]
      assert_equal "patrol", dispatches.first[:slug]
      assert_equal "patrol", dispatches.first[:stage]
      assert_match(
        /\Ahive patrol p1 --json --occurrence-id occ-[0-9a-f]{64}\z/,
        dispatches.first[:command]
      )
      assert scheduler.pending?("p1")
      state = Hive::Patrol::StateStore.new(dir)
      occurrence = state.pending_occurrences.fetch(0)
      capture = state.occurrence_capture(occurrence.fetch("occurrence_id"))
      assert_equal "reserved", occurrence.fetch("phase")
      assert_equal capture.occurrence_id,
                   dispatches.first.fetch(:command).split.last

      evidence = Hive::Modules::Migration::EvidenceStore.new(
        root: File.join(
          entry.fetch("hive_state_path"), "module-runtime", "migration",
          "patrol-evidence"
        )
      )
      assert_empty evidence.captures,
                   "a reservation is provisional, not comparison evidence"
      events = Hive::Modules::EventLedger.new(
        root: File.join(entry.fetch("hive_state_path"), "module-runtime")
      ).all
      assert_empty events,
                   "the schedule event must contain the finalized outcome"
      assert_empty scheduler.tick(now: T0 + 1),
                   "pending patrol child must not be re-dispatched"
    end
  end

  def test_candidate_boundary_preserves_identity_and_reservation_rechecks_ownership
    with_tmp_dir do |dir|
      write_state(dir, "last_scanned_sha" => "old")
      entry = project_entry(dir)
      ownership_allowed = true
      ownership_checks = []
      sched = Hive::Daemon::PatrolScheduler.new(
        registry: -> { [ entry ] },
        config_loader: ->(_path) { enabled_cfg },
        git: FakeGit.new,
        migration_ownership: lambda do |candidate_entry, module_name, authority|
          ownership_checks << [ candidate_entry, module_name, authority ]
          ownership_allowed
        end
      )

      candidate = sched.candidates(now: T0).fetch(0)

      assert_equal(
        {
          project: "p1",
          slug: "patrol",
          stage: "patrol",
          command: "hive patrol p1 --json",
          patrol_kind: :ordinary,
          state_file_mtime: nil,
          state_file_path: nil,
          hive_state_path: entry.fetch("hive_state_path"),
          migration_entry: entry
        },
        candidate
      )
      refute sched.pending?("p1"), "candidate discovery must not consume the patrol turn"

      ownership_allowed = false
      assert_nil sched.reserve(candidate, now: T0)
      refute sched.pending?("p1"), "a reservation-time ownership fence must not mark pending"

      ownership_allowed = true
      dispatch = sched.reserve(candidate, now: T0)
      assert_equal(
        candidate.reject { |key, _value| %i[patrol_kind command].include?(key) },
        dispatch.reject { |key, _value| key == :command }
      )
      assert_match(/ --occurrence-id occ-[0-9a-f]{64}\z/, dispatch.fetch(:command))
      refute_includes dispatch.keys, :patrol_kind
      assert sched.pending?("p1")
      assert_equal(
        [
          [ entry, "patrol", :legacy ],
          [ entry, "patrol", :legacy ],
          [ entry, "patrol", :legacy ]
        ],
        ownership_checks
      )

      config_loads = 0
      fenced = Hive::Daemon::PatrolScheduler.new(
        registry: -> { [ entry ] },
        config_loader: lambda do |_path|
          config_loads += 1
          enabled_cfg
        end,
        git: FakeGit.new,
        migration_ownership: ->(*) { false }
      )
      assert_empty fenced.candidates(now: T0)
      assert_equal 0, config_loads, "a fenced project must stop before config and due checks"
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
      assert_equal 1, sched.tick(now: T0).size

      sched.complete(project: "p1", exit_code: 1, now: T0 + 10)
      refute sched.pending?("p1")
      assert_empty sched.tick(now: T0 + 30),
                   "failed patrol should respect the first backoff interval"

      # A project with an outstanding failure retries on the backoff
      # cadence (60s), not the slow poll interval — the throttle is
      # exempt while a failure is recorded.
      assert_equal 1, sched.tick(now: T0 + 71).size,
                   "failed patrol retries once the backoff interval elapses"

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
    sched.cancel(project: "p1")
    refute sched.pending?("p1")

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
        git: FakeGit.new(sha: "new")
      )

      assert_equal 1, sched.tick(now: T0).size
    end
  end

  def test_pending_occurrence_is_selected_oldest_and_reserved_for_recovery
    with_tmp_dir do |dir|
      entry = project_entry(dir)
      capture = reservation_capture(entry)
      reservations = []
      store = Object.new
      store.define_singleton_method(:projection_pending_occurrences) { [] }
      store.define_singleton_method(:pending_occurrences) do
        [
          {
            "occurrence_id" => "occ-#{'b' * 64}",
            "created_at" => (T0 + 1).iso8601(6)
          },
          {
            "occurrence_id" => capture.occurrence_id,
            "created_at" => T0.iso8601(6)
          }
        ]
      end
      store.define_singleton_method(:occurrence_capture) do |occurrence_id|
        capture if occurrence_id == capture.occurrence_id
      end
      store.define_singleton_method(:reserve_occurrence!) do |reserved, now:|
        reservations << [ reserved, now ]
      end
      sched = Hive::Daemon::PatrolScheduler.new(
        registry: -> { [ entry ] },
        config_loader: ->(_path) { raise "recovery must not reload config" },
        migration_ownership: ->(*) { true },
        migration_snapshot: ->(*) { legacy_migration_snapshot },
        state_store_factory: ->(_candidate) { store }
      )

      candidate = sched.candidates(now: T0 + 2).fetch(0)
      dispatch = sched.reserve(candidate, now: T0 + 2)

      assert_equal capture.occurrence_id, candidate.fetch(:recovery_occurrence_id)
      assert_includes dispatch.fetch(:command), "--occurrence-id #{capture.occurrence_id}"
      assert_equal [ [ capture, T0 + 2 ] ], reservations
      assert sched.pending?("p1")
    end
  end

  def test_projection_recovery_drains_every_pending_occurrence_before_ownership_gate
    with_tmp_dir do |dir|
      entry = project_entry(dir)
      drained = []
      evidence = Object.new
      publisher = Object.new
      store = Object.new
      store.define_singleton_method(:projection_pending_occurrences) do
        [
          { "occurrence_id" => "occ-#{'a' * 64}" },
          { "occurrence_id" => "occ-#{'b' * 64}" }
        ]
      end
      store.define_singleton_method(:drain_occurrence_outbox!) do |occurrence_id, **options|
        drained << [ occurrence_id, options ]
      end
      sched = Hive::Daemon::PatrolScheduler.new(
        registry: -> { [ entry ] },
        migration_ownership: ->(*) { false },
        evidence_store_factory: ->(_candidate) { evidence },
        event_publisher: publisher,
        state_store_factory: ->(_candidate) { store }
      )

      assert_empty sched.candidates(now: T0)
      assert_equal(
        [ "occ-#{'a' * 64}", "occ-#{'b' * 64}" ],
        drained.map(&:first)
      )
      drained.each do |_occurrence_id, options|
        assert_same evidence, options.fetch(:evidence_store)
        assert_same publisher, options.fetch(:event_publisher)
        assert_equal entry, options.fetch(:project_entry)
      end
    end
  end

  def test_already_finalized_negative_occurrence_only_replays_its_outbox
    with_tmp_dir do |dir|
      entry = project_entry(dir)
      evidence = Object.new
      publisher = Object.new
      reserved = []
      drained = []
      store = Object.new
      store.define_singleton_method(:projection_pending_occurrences) { [] }
      store.define_singleton_method(:pending_occurrences) { [] }
      store.define_singleton_method(:reserve_occurrence!) do |capture, now:|
        reserved << [ capture, now ]
      end
      store.define_singleton_method(:occurrence) do |occurrence_id|
        raise "unknown occurrence" unless occurrence_id == reserved.last.first.occurrence_id

        { "phase" => "finalized" }
      end
      store.define_singleton_method(:drain_occurrence_outbox!) do |occurrence_id, **options|
        drained << [ occurrence_id, options ]
      end
      store.define_singleton_method(:finalize_occurrence!) do |**|
        raise "an already-finalized occurrence must not be finalized twice"
      end
      sched = Hive::Daemon::PatrolScheduler.new(
        registry: -> { [ entry ] },
        config_loader: ->(_path) { enabled_cfg("patrol" => { "enabled" => false }) },
        migration_ownership: ->(*) { true },
        migration_snapshot: ->(*) { legacy_migration_snapshot },
        evidence_store_factory: ->(_candidate) { evidence },
        event_publisher: publisher,
        state_store_factory: ->(_candidate) { store }
      )

      assert_empty sched.candidates(now: T0)

      capture, reservation_time = reserved.fetch(0)
      assert_equal "disabled", capture.decision_class
      assert_equal T0, reservation_time
      assert_equal [ capture.occurrence_id ], drained.map(&:first)
      assert_same evidence, drained.first.last.fetch(:evidence_store)
    end
  end

  def test_successful_completion_projects_the_bounded_command_envelope
    with_tmp_dir do |dir|
      write_state(dir, "last_scanned_sha" => "old")
      entry = project_entry(dir)
      sched = scheduler(entry, enabled_cfg)
      sched.tick(now: T0)
      envelope = {
        "ok" => true,
        "features_mapped" => 4,
        "features_reviewed" => 3,
        "review_complete" => false,
        "findings" => 2,
        "fixes_attempted" => 1,
        "prs_opened" => 1,
        "last_scanned_sha" => "a" * 40,
        "ignored" => "must not be projected"
      }

      sched.complete(
        project: "p1", exit_code: Hive::ExitCodes::SUCCESS,
        envelope: envelope, now: T0 + 1
      )

      evidence = Hive::Modules::Migration::EvidenceStore.new(
        root: File.join(
          entry.fetch("hive_state_path"), "module-runtime", "migration",
          "patrol-evidence"
        )
      )
      capture = evidence.captures.fetch(0)
      envelope.except("ok", "ignored").each do |key, value|
        assert_equal value, capture.decision.fetch(key)
      end
      refute capture.decision.key?("ignored")
      refute sched.pending?("p1")
    end
  end

  def test_reservation_failure_after_pending_assignment_rolls_back_pending_state
    with_tmp_dir do |dir|
      entry = project_entry(dir)
      capture = reservation_capture(entry)
      store = Object.new
      store.define_singleton_method(:occurrence_capture) { |_occurrence_id| capture }
      store.define_singleton_method(:reserve_occurrence!) { |_capture, now:| now }
      sched = Hive::Daemon::PatrolScheduler.new(
        registry: -> { [ entry ] },
        migration_ownership: ->(*) { true },
        migration_snapshot: ->(*) { legacy_migration_snapshot },
        state_store_factory: ->(_candidate) { store }
      )
      candidate = sched.send(:dispatch_for, entry)
      candidate[:recovery_occurrence_id] = capture.occurrence_id
      candidate.delete(:command)

      assert_raises(KeyError) { sched.reserve(candidate, now: T0) }
      refute sched.pending?("p1")
    end
  end

  def test_malformed_completion_and_poll_interval_fail_closed
    with_tmp_dir do |dir|
      write_state(dir, "last_scanned_sha" => "old")
      sched = scheduler(project_entry(dir), enabled_cfg)
      sched.tick(now: T0)

      completion_error = assert_raises(Hive::ConfigError) do
        sched.complete(project: "p1", exit_code: "invalid", envelope: {}, now: T0 + 1)
      end
      interval_error = assert_raises(Hive::ConfigError) do
        sched.send(:schedule_window, T0, "invalid")
      end

      assert_equal "patrol completion outcome is malformed", completion_error.message
      assert_equal "patrol poll interval is malformed", interval_error.message
      assert sched.pending?("p1"), "a malformed completion must not discard recovery state"
    end
  end

  private

  def legacy_migration_snapshot
    { "owner" => "legacy", "admission" => true, "epoch" => 1 }
  end

  def reservation_capture(entry)
    Hive::Modules::Migration::PatrolCapture.build(
      module_name: "patrol",
      project: {
        "project_id" => entry.fetch("project_id"),
        "name" => entry.fetch("name"),
        "repository" => entry["repository"]
      },
      trigger: {
        "kind" => "schedule",
        "id" => "ordinary:#{entry.fetch('project_id')}:#{T0.iso8601(6)}"
      },
      reservation: {
        "kind" => "ordinary",
        "id" => "ordinary:#{entry.fetch('project_id')}:#{T0.iso8601(6)}"
      },
      owner: "legacy",
      owner_epoch: 1,
      decision_class: "due",
      decision: { "rationale" => "due" },
      occurred_at: T0,
      recorded_at: T0
    )
  end
end
