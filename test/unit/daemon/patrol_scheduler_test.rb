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

    def ancestor?(_project_root, _ancestor, _descendant)
      true
    end
  end

  FakeArchitectureSnapshot = Struct.new(:root_realpath, :branch, :default_branch, :head_sha, :released, keyword_init: true) do
    def release
      self.released = true
    end
  end

  class FakeArchitectureGuard
    attr_reader :snapshots

    def initialize(root, head: "head")
      @root = root
      @head = head
      @snapshots = []
    end

    def acquire!
      snapshot = FakeArchitectureSnapshot.new(
        root_realpath: File.realpath(@root), branch: "main", default_branch: "main",
        head_sha: @head, released: false
      )
      @snapshots << snapshot
      snapshot
    end

    def assert_unchanged!(_snapshot)
      true
    end
  end

  CapabilityResult = Struct.new(:ok?, :reason, :evidence, :executable)
  CatalogResult = Struct.new(:merges, :diagnostics)
  ScopeResult = Struct.new(:runnable?, :reason, :evidence, :kind, :values, :fallback, :arguments) do
    def to_h
      { "kind" => kind, "values" => values, "fallback" => fallback }
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
    { "name" => name, "path" => dir, "hive_state_path" => File.join(dir, ".hive-state") }
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

  def test_new_commit_dispatches_patrol_once_and_marks_pending
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

  def test_due_patrol_seeds_then_drains_one_attributed_architecture_child
    with_tmp_dir do |dir|
      entry = project_entry(dir)
      cfg = enabled_cfg("refactor_patrol" => { "enabled" => true })
      write_state(dir, "last_scanned_sha" => "base")
      post_merge = Hive::RefactorPatrol::PostMergeStateStore.new(dir, project: "p1")
      post_merge.initialize_at!(head_sha: "base", now: T0)
      guard = FakeArchitectureGuard.new(dir)
      catalog = CatalogResult.new(
        [ { "pr_number" => 10, "merge_sha" => "head", "base_sha" => "base",
            "subject" => "Change (#10)", "changed_paths" => [ "lib/a.rb" ] } ],
        []
      )
      scope = ScopeResult.new(true, nil, {}, "path", [ "lib" ], false,
                              [ "--changed-since", "base", "--path", "lib" ])
      sched = architecture_scheduler(entry, cfg, post_merge: post_merge, guard: guard,
                                                  catalog: catalog, scope: scope)

      first_tick = sched.tick(now: T0)
      assert_equal [ "hive patrol p1 --json" ], first_tick.map { |item| item.fetch(:command) }
      assert_equal "head", post_merge.state.fetch("active_batch_head")

      sched.complete(project: "p1", exit_code: 0, stage: "patrol", slug: "patrol", now: T0 + 1)
      second_tick = sched.tick(now: T0 + 2)
      assert_equal 1, second_tick.size
      architecture = second_tick.first
      assert_equal "refactor-patrol-post-merge", architecture.fetch(:stage)
      assert_equal "refactor-patrol-pr-10-head", architecture.fetch(:slug)
      assert_equal "/tmp/hive-local refactor-patrol p1 --json --changed-since base --path lib",
                   architecture.fetch(:command)
      assert_equal :architecture, architecture.fetch(:patrol_product)
    end
  end

  def test_invalid_architecture_completion_leaves_pr_owed_and_releases_snapshot
    with_tmp_dir do |dir|
      entry = project_entry(dir)
      cfg = enabled_cfg(
        "patrol" => { "enabled" => true, "trigger" => "new_commits" },
        "refactor_patrol" => { "enabled" => true }
      )
      write_state(dir, "last_scanned_sha" => "head")
      post_merge = Hive::RefactorPatrol::PostMergeStateStore.new(dir, project: "p1")
      post_merge.initialize_at!(head_sha: "base", now: T0)
      post_merge.open_batch!(
        head_sha: "head",
        merges: [ { "pr_number" => 10, "merge_sha" => "head", "base_sha" => "base",
                    "subject" => "Change (#10)", "changed_paths" => [ "lib/a.rb" ] } ],
        now: T0
      )
      guard = FakeArchitectureGuard.new(dir)
      sched = architecture_scheduler(
        entry,
        cfg,
        post_merge: post_merge,
        guard: guard,
        catalog: CatalogResult.new([], []),
        scope: ScopeResult.new(true, nil, {}, "path", [ "lib" ], true,
                               [ "--changed-since", "base", "--path", "lib" ])
      )

      dispatch = sched.tick(now: T0 + 1).fetch(0)
      sched.complete(
        project: "p1", exit_code: 0, stage: dispatch.fetch(:stage), slug: dispatch.fetch(:slug),
        envelope: { "schema" => "wrong", "ok" => true }, now: T0 + 2
      )

      assert_equal [ post_merge.identity_for(10, "head") ],
                   post_merge.owed_merges.map { |record| record.fetch("identity") }
      assert guard.snapshots.last.released
      assert_equal "invalid_envelope", sched.last_events.last.fetch(:reason)
    end
  end

  def test_completion_error_after_durable_artifacts_reconciles_as_processed
    with_tmp_dir do |dir|
      entry = project_entry(dir)
      cfg = enabled_cfg(
        "patrol" => { "enabled" => true, "trigger" => "new_commits" },
        "refactor_patrol" => { "enabled" => true }
      )
      write_state(dir, "last_scanned_sha" => "head")
      post_merge = Hive::RefactorPatrol::PostMergeStateStore.new(dir, project: "p1")
      post_merge.initialize_at!(head_sha: "base", now: T0)
      post_merge.open_batch!(
        head_sha: "head",
        merges: [ { "pr_number" => 10, "merge_sha" => "head", "base_sha" => "base",
                    "subject" => "Change (#10)", "changed_paths" => [ "lib/a.rb" ] } ],
        now: T0
      )
      completion = lambda do |token:, state_store:, now:, **|
        state_store.complete!(
          token.fetch("identity"),
          report: successful_report(token, now),
          emission_digests: {},
          now: now
        )
        raise Hive::Error, "simulated error after the completion write"
      end
      sched = architecture_scheduler(
        entry,
        cfg,
        post_merge: post_merge,
        guard: FakeArchitectureGuard.new(dir),
        catalog: CatalogResult.new([], []),
        scope: ScopeResult.new(true, nil, {}, "path", [ "lib" ], true,
                               [ "--changed-since", "base", "--path", "lib" ]),
        architecture_completion: completion
      )

      dispatch = sched.tick(now: T0 + 1).fetch(0)
      sched.complete(
        project: "p1", exit_code: 0, stage: dispatch.fetch(:stage), slug: dispatch.fetch(:slug),
        envelope: { "schema" => "hive-refactor-patrol", "ok" => true, "project" => "p1",
                    "project_root" => File.realpath(dir) },
        now: T0 + 2
      )

      assert_equal "processed", post_merge.merge_record(post_merge.identity_for(10, "head")).fetch("status")
      assert_equal :architecture_completed, sched.last_events.last.fetch(:type)
      assert_equal "reconciled", sched.last_events.last.fetch(:reason)
    end
  end

  def test_capability_block_does_not_replace_ordinary_patrol
    with_tmp_dir do |dir|
      entry = project_entry(dir)
      cfg = enabled_cfg("refactor_patrol" => { "enabled" => true })
      write_state(dir, "last_scanned_sha" => "base")
      post_merge = Hive::RefactorPatrol::PostMergeStateStore.new(dir, project: "p1")
      post_merge.initialize_at!(head_sha: "base", now: T0)
      guard = FakeArchitectureGuard.new(dir)
      sched = architecture_scheduler(
        entry,
        cfg,
        post_merge: post_merge,
        guard: guard,
        catalog: CatalogResult.new([], []),
        scope: nil,
        capability: CapabilityResult.new(false, "capability_missing", { "message" => "missing" }, nil)
      )

      assert_equal [ "hive patrol p1 --json" ], sched.tick(now: T0).map { |item| item.fetch(:command) }
      assert_equal "capability_missing", sched.last_events.last.fetch(:reason)
      assert guard.snapshots.last.released
    end
  end

  def test_dry_run_records_attributed_command_without_mutating_post_merge_state
    with_tmp_dir do |dir|
      entry = project_entry(dir)
      cfg = enabled_cfg("refactor_patrol" => { "enabled" => true })
      write_state(dir, "last_scanned_sha" => "base")
      post_merge = Hive::RefactorPatrol::PostMergeStateStore.new(dir, project: "p1")
      post_merge.initialize_at!(head_sha: "base", now: T0)
      before = File.binread(File.join(post_merge.root, "state.json"))
      guard = FakeArchitectureGuard.new(dir)
      catalog = CatalogResult.new(
        [ { "pr_number" => 10, "merge_sha" => "head", "base_sha" => "base",
            "subject" => "Change (#10)", "changed_paths" => [ "lib/a.rb" ] } ],
        []
      )
      scope = ScopeResult.new(true, nil, {}, "path", [ "lib" ], true,
                              [ "--changed-since", "base", "--path", "lib" ])
      sched = architecture_scheduler(entry, cfg, post_merge: post_merge, guard: guard,
                                                  catalog: catalog, scope: scope, dry_run: true)

      assert_equal "hive patrol p1 --json", sched.tick(now: T0).first.fetch(:command)
      sched.complete(project: "p1", exit_code: 0, stage: "patrol", now: T0 + 1)
      architecture = sched.tick(now: T0 + 2).first

      assert_equal "refactor-patrol-post-merge", architecture.fetch(:stage)
      sched.complete(project: "p1", exit_code: 0, stage: architecture.fetch(:stage),
                     slug: architecture.fetch(:slug), now: T0 + 3)
      assert_equal :architecture_dry_run_completed, sched.last_events.last.fetch(:type)
      assert_equal before, File.binread(File.join(post_merge.root, "state.json"))
      refute File.exist?(File.join(post_merge.root, "emissions.json"))
      assert_empty Dir.glob(File.join(post_merge.root, "reports", "*.json"))
    end
  end

  def test_default_architecture_factories_git_helper_and_event_drain
    with_tmp_git_repo do |repo|
      entry = project_entry(repo)
      cfg = enabled_cfg("default_branch" => "master")
      sched = Hive::Daemon::PatrolScheduler.new(registry: -> { [] })

      assert_instance_of Hive::RefactorPatrol::CheckoutGuard,
                         sched.instance_variable_get(:@checkout_guard_factory).call(entry, cfg)
      assert_instance_of Hive::RefactorPatrol::LocalMergeCatalog,
                         sched.instance_variable_get(:@merge_catalog_factory).call(entry)
      assert_instance_of Hive::RefactorPatrol::PostMergeScope,
                         sched.instance_variable_get(:@scope_factory).call(entry, cfg)
      assert_equal({}, sched.instance_variable_get(:@fingerprint_loader).call(repo))
      head = run!("git", "-C", repo, "rev-parse", "HEAD").strip
      assert Hive::Daemon::PatrolScheduler::GitHelper.new.ancestor?(repo, head, head)

      sched.send(:record_event, :blocked, project: "p1", reason: "test")
      assert_equal 1, sched.drain_events.size
      assert_empty sched.drain_events

      unavailable = Hive::Daemon::PatrolScheduler.new(
        registry: -> { [] }, architecture_store_factory: ->(_entry) { raise Hive::Error, "no state" }
      )
      refute unavailable.send(:architecture_batch_active?, entry)
    end
  end

  def test_first_due_tick_initializes_baseline_even_when_soft_ancestry_is_unknown
    with_tmp_dir do |dir|
      entry = project_entry(dir)
      cfg = enabled_cfg("refactor_patrol" => { "enabled" => true })
      write_state(dir, "last_scanned_sha" => "base")
      post_merge = Hive::RefactorPatrol::PostMergeStateStore.new(dir, project: "p1")
      git = Class.new(FakeGit) do
        def ancestor?(*_args)
          raise Hive::GitError, "soft diagnostic unavailable"
        end
      end.new(sha: "head")
      sched = architecture_scheduler(
        entry, cfg, post_merge: post_merge, guard: FakeArchitectureGuard.new(dir),
        catalog: CatalogResult.new([], []), scope: nil, git: git
      )

      assert_equal [ "hive patrol p1 --json" ], sched.tick(now: T0).map { |item| item.fetch(:command) }
      assert post_merge.initialized?
      assert_nil post_merge.state.dig("diagnostics", "capability_merge_ancestor")
    end
  end

  def test_active_batch_blocks_capability_movement_scope_and_checkout_without_ordinary_failure
    with_tmp_dir do |dir|
      entry, cfg, post_merge = active_architecture_context(dir)
      sched = architecture_scheduler(
        entry, cfg, post_merge: post_merge, guard: FakeArchitectureGuard.new(dir),
        catalog: CatalogResult.new([], []), scope: nil,
        capability: CapabilityResult.new(false, "capability_missing", {}, nil)
      )
      assert_empty sched.tick(now: T0 + 1)
      assert_equal "capability_missing", sched.last_events.last.fetch(:reason)
    end

    with_tmp_dir do |dir|
      entry, cfg, post_merge = active_architecture_context(dir)
      sched = architecture_scheduler(
        entry, cfg, post_merge: post_merge, guard: FakeArchitectureGuard.new(dir, head: "other"),
        catalog: CatalogResult.new([], []), scope: nil
      )
      assert_empty sched.tick(now: T0 + 1)
      assert_equal "checkout_moved", sched.last_events.last.fetch(:reason)
    end

    with_tmp_dir do |dir|
      entry, cfg, post_merge = active_architecture_context(dir)
      unusable = ScopeResult.new(false, "scope_unusable", { "detail" => "empty" }, nil, [], false, [])
      sched = architecture_scheduler(
        entry, cfg, post_merge: post_merge, guard: FakeArchitectureGuard.new(dir),
        catalog: CatalogResult.new([], []), scope: unusable
      )
      assert_empty sched.tick(now: T0 + 1)
      assert_equal "scope_unusable", sched.last_events.last.fetch(:reason)
    end

    with_tmp_dir do |dir|
      entry, cfg, post_merge = active_architecture_context(dir)
      blocked_guard = Object.new
      blocked_guard.define_singleton_method(:acquire!) do
        raise Hive::RefactorPatrol::CheckoutGuard::Blocked.new("checkout_dirty", "dirty")
      end
      sched = architecture_scheduler(
        entry, cfg, post_merge: post_merge, guard: blocked_guard,
        catalog: CatalogResult.new([], []), scope: nil
      )
      assert_empty sched.tick(now: T0 + 1)
      assert_equal "checkout_dirty", sched.last_events.last.fetch(:reason)
    end
  end

  def test_seed_guard_and_catalog_errors_are_retryable_and_store_errors_still_emit_events
    with_tmp_dir do |dir|
      entry, cfg, post_merge = active_architecture_context(dir, ordinary_sha: "base")
      blocked_guard = Object.new
      blocked_guard.define_singleton_method(:acquire!) do
        raise Hive::RefactorPatrol::CheckoutGuard::Blocked.new("checkout_busy", "busy")
      end
      sched = architecture_scheduler(
        entry, cfg, post_merge: post_merge, guard: blocked_guard,
        catalog: CatalogResult.new([], []), scope: nil
      )
      assert_equal [ "hive patrol p1 --json" ], sched.tick(now: T0 + 1).map { |item| item.fetch(:command) }
      assert_equal "checkout_busy", sched.last_events.last.fetch(:reason)
    end

    with_tmp_dir do |dir|
      entry, cfg, post_merge = active_architecture_context(dir, ordinary_sha: "base")
      catalog_error = Hive::RefactorPatrol::LocalMergeCatalog::CatalogError.new(
        "checkpoint_unreachable", "rewritten"
      )
      catalog = Object.new
      catalog.define_singleton_method(:discover) { |**| raise catalog_error }
      sched = Hive::Daemon::PatrolScheduler.new(
        registry: -> { [ entry ] }, config_loader: ->(_path) { cfg }, git: FakeGit.new(sha: "head"),
        architecture_store_factory: ->(_entry) { post_merge },
        checkout_guard_factory: ->(_entry, _config) { FakeArchitectureGuard.new(dir) },
        capability_probe_factory: ->(*) { Struct.new(:result) { def call(_root) = result }.new(CapabilityResult.new(true, nil, {}, "/tmp/hive")) },
        merge_catalog_factory: ->(_entry) { catalog }
      )
      assert_equal [ "hive patrol p1 --json" ], sched.tick(now: T0 + 1).map { |item| item.fetch(:command) }
      assert_equal "checkpoint_unreachable", sched.last_events.last.fetch(:reason)
    end

    entry = { "name" => "p1", "path" => "/missing" }
    sched = Hive::Daemon::PatrolScheduler.new(
      registry: -> { [] }, architecture_store_factory: ->(_entry) { raise Hive::Error, "broken state" }
    )
    sched.send(:block_first_owed, entry, reason: "checkout_missing", evidence: {}, now: T0)
    assert_equal "checkout_missing", sched.last_events.last.fetch(:reason)
  end

  def test_architecture_nonzero_cancel_reporter_and_reconciliation_paths_remain_owed
    with_tmp_dir do |dir|
      entry, cfg, post_merge = active_architecture_context(dir)
      guard = FakeArchitectureGuard.new(dir)
      scope = ScopeResult.new(true, nil, {}, "path", [ "lib" ], true,
                              [ "--changed-since", "base", "--path", "lib" ])
      completion_error = Hive::RefactorPatrol::PostMergeReporter::ReportError.new("report_failed", "failed")
      sched = architecture_scheduler(
        entry, cfg, post_merge: post_merge, guard: guard, catalog: CatalogResult.new([], []), scope: scope,
        architecture_completion: ->(**) { raise completion_error }
      )

      dispatch = sched.tick(now: T0 + 1).fetch(0)
      envelope = { "schema" => "hive-refactor-patrol", "ok" => true, "project" => "p1",
                   "project_root" => File.realpath(dir) }
      sched.complete(project: "p1", exit_code: 0, stage: dispatch.fetch(:stage), slug: dispatch.fetch(:slug),
                     envelope: envelope, now: T0 + 2)
      assert_equal "report_failed", sched.last_events.last.fetch(:reason)

      dispatch = sched.tick(now: T0 + 3).fetch(0)
      sched.complete(project: "p1", exit_code: 9, stage: dispatch.fetch(:stage), slug: dispatch.fetch(:slug),
                     now: T0 + 4)
      assert_equal "child_exit_nonzero", sched.last_events.last.fetch(:reason)

      dispatch = sched.tick(now: T0 + 5).fetch(0)
      sched.cancel(project: "p1", stage: dispatch.fetch(:stage), slug: dispatch.fetch(:slug),
                   reason: "capacity", now: T0 + 6)
      refute sched.architecture_pending?("p1")

      dispatch = sched.tick(now: T0 + 7).fetch(0)
      sched.instance_variable_set(:@architecture_completion, nil)
      sched.complete(project: "p1", exit_code: 0, stage: dispatch.fetch(:stage), slug: dispatch.fetch(:slug),
                     envelope: envelope, now: T0 + 8)
      assert_equal "reporter_unavailable", sched.last_events.last.fetch(:reason)
      assert guard.snapshots.all?(&:released)

      assert_equal File.expand_path(File.join(dir, "gone")), sched.send(:canonical_path, File.join(dir, "gone"))
    end

    sched = Hive::Daemon::PatrolScheduler.new(registry: -> { [] })
    sched.send(:reconcile_completion_error, nil, project: "p1", error: Hive::Error.new("no pending"), now: T0)
    assert_equal "completion_failed", sched.last_events.last.fetch(:reason)

    owed_store = Object.new
    owed_store.define_singleton_method(:merge_record) { |_identity| { "status" => "owed" } }
    pending = { store: owed_store, identity: "pr-1-head" }
    sched.send(:reconcile_completion_error, pending, project: "p1", error: Hive::Error.new("already owed"), now: T0)
    assert_equal "completion_failed", sched.last_events.last.fetch(:reason)

    broken_store = Object.new
    broken_store.define_singleton_method(:merge_record) { |_identity| raise Hive::Error, "state broken" }
    pending = { store: broken_store, identity: "pr-1-head" }
    sched.send(:reconcile_completion_error, pending, project: "p1", error: Hive::Error.new("completion"), now: T0)
    assert_equal "state broken", sched.last_events.last.dig(:evidence, "state_error")
  end

  private

  def architecture_scheduler(entry, cfg, post_merge:, guard:, catalog:, scope:, capability: nil, dry_run: false,
                             architecture_completion: nil, git: FakeGit.new(sha: "head"))
    capability ||= CapabilityResult.new(true, nil, {}, "/tmp/hive-local")
    Hive::Daemon::PatrolScheduler.new(
      registry: -> { [ entry ] },
      config_loader: ->(_path) { cfg },
      git: git,
      architecture_store_factory: ->(_entry) { post_merge },
      checkout_guard_factory: ->(_entry, _config) { guard },
      capability_probe_factory: ->(_entry, _config) { Struct.new(:result) { def call(_root) = result }.new(capability) },
      merge_catalog_factory: ->(_entry) { Struct.new(:result) { def discover(**) = result }.new(catalog) },
      scope_factory: ->(_entry, _config) { Struct.new(:result) { def select(**) = result }.new(scope) },
      fingerprint_loader: ->(_root) { {} },
      architecture_completion: architecture_completion,
      dry_run: dry_run
    )
  end

  def active_architecture_context(dir, ordinary_sha: "head")
    entry = project_entry(dir)
    cfg = enabled_cfg(
      "patrol" => { "enabled" => true, "trigger" => "new_commits" },
      "refactor_patrol" => { "enabled" => true }
    )
    write_state(dir, "last_scanned_sha" => ordinary_sha)
    post_merge = Hive::RefactorPatrol::PostMergeStateStore.new(dir, project: "p1")
    post_merge.initialize_at!(head_sha: "base", now: T0)
    post_merge.open_batch!(
      head_sha: "head",
      merges: [ { "pr_number" => 10, "merge_sha" => "head", "base_sha" => "base",
                  "subject" => "Change (#10)", "changed_paths" => [ "lib/a.rb" ] } ],
      now: T0
    )
    [ entry, cfg, post_merge ]
  end

  def successful_report(token, now)
    {
      "completion_status" => "success",
      "analysis_sha" => token.fetch("pinned_head"),
      "changed_paths" => token.fetch("changed_paths"),
      "scope" => token.fetch("scope"),
      "totals" => { "accepted" => 0, "flagged" => 0, "suppressed" => 0 },
      "flagged_theses" => [],
      "emitted_delta" => [],
      "started_at" => token.fetch("started_at"),
      "completed_at" => now.utc.iso8601
    }
  end
end
