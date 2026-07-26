require "test_helper"
require "hive/daemon/pr_merge_watcher"
require "hive/daemon/status_consumer"
require "hive/task_meta"

class HiveDaemonPrMergeWatcherTest < Minitest::Test
  include HiveTestHelper

  T0 = Time.utc(2026, 7, 25, 12)

  class FakeGh
    attr_accessor :state, :reachable, :head_oid, :error
    attr_reader :fact_calls

    def initialize(state: "OPEN")
      @state = state
      @reachable = true
      @head_oid = "b" * 40
      @fact_calls = []
    end

    def repository_identity(*, **)
      { "host" => "github.com", "repository" => "acme/app" }
    end

    def closure_default_branch(**)
      "main"
    end

    def ensure_authenticated!(*)
      true
    end

    def closure_pr_facts(host:, repository:, number:, **kwargs)
      @fact_calls << {
        host: host, repository: repository, number: number,
        timeout_sec: kwargs[:timeout_sec]
      }
      raise error if error

      {
        "repository" => repository,
        "number" => number,
        "url" => "https://#{host}/#{repository}/pull/#{number}",
        "state" => state,
        "merged_at" => state == "MERGED" ? T0.iso8601 : "",
        "merge_oid" => state == "MERGED" ? "a" * 40 : "",
        "head_oid" => head_oid,
        "base_ref_name" => "main",
        "reachable_from_default" => state == "MERGED" && reachable
      }
    end

    def closure_commit_facts(oid:, default_branch:, **)
      {
        "oid" => oid,
        "default_branch" => default_branch,
        "comparison" => reachable ? "ahead" : "diverged",
        "reachable_from_default" => reachable
      }
    end
  end

  class FakeClosure
    attr_accessor :error
    attr_reader :calls

    def initialize
      @calls = []
    end

    def reconcile_remote_merge!(**kwargs)
      @calls << kwargs
      raise error if error

      { "receipt_digest" => Digest::SHA256.hexdigest(kwargs.fetch(:pr_url)) }
    end
  end

  class FakeIntake
    attr_accessor :outcomes, :error
    attr_reader :calls

    def initialize
      @outcomes = []
      @calls = []
    end

    def ingest(**kwargs)
      @calls << kwargs
      raise error if error

      outcomes.empty? ? { "job_id" => "job-1", "manifest_digest" => "m" * 64 } : outcomes.shift
    end
  end

  Row = Struct.new(
    :project, :slug, :id, :stage, :workflow, :marker, :folder,
    :state_file_mtime, :pr_url, :blocked, :admission_error,
    keyword_init: true
  )

  def test_observe_enrolls_every_pr_bearing_stage_and_persists_backlog
    with_merge_project(stages: Hive::Daemon::PrMergeWatcher::SUPPORTED_STAGES) do |tasks, _home|
      watcher, store = build_watcher
      results = watcher.observe(tasks.map { |task| row_for(task) }, now: T0)

      assert_equal [ :observed ], results.map { |result| result.fetch(:status) }.uniq
      assert_equal 4, watcher.pending_count
      state = store.load(identity_for(tasks.first.project_root))
      assert_equal 4, state.fetch("candidates").length
      assert_equal true, state.dig("backlog", "complete")
      assert_equal T0.iso8601(6), state.dig("backlog", "scanned_at")
      assert_equal 4, state.dig("backlog", "outcomes").length
      assert state.dig("backlog", "outcomes").values.all? do |outcome|
        outcome.fetch("status") == "candidate" &&
          outcome.fetch("candidate_key")
      end
    end
  end

  def test_zero_row_project_gets_a_durable_complete_backlog
    with_merge_project(stages: [ "5-open-pr" ]) do |tasks, _home|
      watcher, store = build_watcher

      result = watcher.observe([], projects: [ "app" ], now: T0).first

      assert_equal :observed, result.fetch(:status)
      assert_equal 0, result.fetch(:candidates)
      state = store.load(identity_for(tasks.first.project_root))
      assert_equal true, state.dig("backlog", "complete")
      assert_empty state.dig("backlog", "outcomes")
    end
  end

  def test_observe_retains_held_and_cross_repository_rows_but_excludes_non_coding_rows
    with_merge_project(stages: [ "5-open-pr", "6-review" ]) do |tasks, _home|
      watcher, store = build_watcher
      base = row_for(tasks.first)
      held = base.dup.tap { |row| row.blocked = true }
      generic = base.dup.tap { |row| row.workflow = "content" }
      cross = row_for(tasks.last).dup.tap do |row|
        row.pr_url = "https://github.com/other/repo/pull/9"
      end

      result = watcher.observe([ held, generic, cross ], now: T0).first

      assert_equal :observed, result.fetch(:status)
      assert_equal 2, result.fetch(:candidates)
      assert_equal 2, watcher.pending_count
      assert_empty watcher.tick(now: T0)
      candidates = store.load(identity_for(tasks.first.project_root))
                        .fetch("candidates").values
      dependency = candidates.find { |item| item.dig("task", "slug") == tasks.first.slug }
      mismatch = candidates.find { |item| item.dig("task", "slug") == tasks.last.slug }
      assert_equal true, dependency.dig("observation", "held")
      assert_equal "dependency_blocked", dependency.dig("observation", "hold_reason")
      assert_equal true, mismatch.dig("observation", "held")
      assert_equal "pull_request_repository_mismatch",
                   mismatch.dig("observation", "hold_reason")

      watcher.observe([ base ], now: T0 + 1)
      candidate = store.load(identity_for(tasks.first.project_root))
                       .fetch("candidates").values
                       .find { |item| item.dig("task", "slug") == tasks.first.slug }
      assert_equal false, candidate.dig("observation", "held")
      assert_equal :open, watcher.tick(now: T0 + 1).first.fetch(:status)
    end
  end

  def test_invalid_pr_url_is_reported_without_hiding_other_candidates
    with_merge_project(stages: [ "5-open-pr", "6-review" ]) do |tasks, _home|
      watcher, store = build_watcher
      invalid = row_for(tasks.first).dup.tap do |row|
        row.pr_url = "https://github.com/acme/app/issues/9"
      end

      results = watcher.observe([ invalid, row_for(tasks.last) ], now: T0)

      assert_equal :observed, results.first.fetch(:status)
      assert_equal 1, results.first.fetch(:candidates)
      blocked = results.last
      assert_equal :blocked, blocked.fetch(:status)
      assert_equal tasks.first.slug, blocked.fetch(:slug)
      assert_match(/canonical GitHub pull request/, blocked.fetch(:reason))
      assert_equal 1, watcher.pending_count
      outcomes = store.load(identity_for(tasks.first.project_root))
                      .dig("backlog", "outcomes").values
      rejected = outcomes.find { |outcome| outcome.fetch("slug") == tasks.first.slug }
      assert_equal "rejected", rejected.fetch("status")
      assert_match(/canonical GitHub pull request/, rejected.fetch("reason"))
      assert_nil rejected.fetch("candidate_key")
    end
  end

  def test_open_and_closed_unmerged_candidates_remain_durable
    with_merge_project(stages: [ "5-open-pr" ]) do |tasks, _home|
      gh = FakeGh.new(state: "OPEN")
      watcher, store = build_watcher(gh: gh, poll_interval_sec: 60)
      watcher.observe([ row_for(tasks.first) ], now: T0)

      assert_equal :open, watcher.tick(now: T0).first.fetch(:status)
      assert_equal "OPEN", watcher.state_for(project: "app", slug: tasks.first.slug)
      assert_empty watcher.tick(now: T0 + 30)

      gh.state = "CLOSED"
      restarted = build_watcher(
        gh: gh, store: store, poll_interval_sec: 60
      ).first
      restarted.observe([ row_for(tasks.first) ], now: T0 + 61)
      result = restarted.tick(now: T0 + 61).first

      assert_equal :closed_unmerged, result.fetch(:status)
      assert restarted.watching?(project: "app", slug: tasks.first.slug)
      assert_equal "CLOSED_UNMERGED",
                   restarted.state_for(project: "app", slug: tasks.first.slug)
    end
  end

  def test_merged_candidate_requires_architecture_intake_then_archives
    with_merge_project(stages: [ "6-review" ]) do |tasks, _home|
      gh = FakeGh.new(state: "MERGED")
      closure = FakeClosure.new
      intake = FakeIntake.new
      watcher, store = build_watcher(
        gh: gh, task_closure: closure, merge_intake: intake
      )
      watcher.observe([ row_for(tasks.first) ], now: T0)

      result = watcher.tick(now: T0).first

      assert_equal :archived, result.fetch(:status)
      assert_equal 1, intake.calls.length
      assert_equal 1, closure.calls.length
      state = store.load(identity_for(tasks.first.project_root))
      candidate = state.fetch("candidates").values.first
      assert_equal "accepted", candidate.dig("architecture", "status")
      assert_equal "archived", candidate.dig("archive", "status")
      assert_match(/\A[a-f0-9]{64}\z/, candidate.dig("archive", "receipt_digest"))
    end
  end

  def test_deferred_architecture_intake_resumes_without_repolling_github
    with_merge_project(stages: [ "7-artifacts" ]) do |tasks, _home|
      gh = FakeGh.new(state: "MERGED")
      closure = FakeClosure.new
      intake = FakeIntake.new
      intake.outcomes = [ :deferred, { "job_id" => "job-2" } ]
      watcher, store = build_watcher(
        gh: gh, task_closure: closure, merge_intake: intake,
        poll_interval_sec: 60
      )
      watcher.observe([ row_for(tasks.first) ], now: T0)

      assert_equal :deferred, watcher.tick(now: T0).first.fetch(:status)
      assert_empty watcher.tick(now: T0 + 30)
      restarted = build_watcher(
        gh: gh, task_closure: closure, merge_intake: intake,
        store: store, poll_interval_sec: 60
      ).first
      restarted.observe([ row_for(tasks.first) ], now: T0 + 61)
      assert_equal :archived, restarted.tick(now: T0 + 61).first.fetch(:status)

      assert_equal 1, gh.fact_calls.length,
                   "stored merge evidence should avoid a redundant poll before intake retry"
      assert_equal 2, intake.calls.length
    end
  end

  def test_architecture_intake_failure_is_durable_and_retryable
    with_merge_project(stages: [ "7-artifacts" ]) do |tasks, _home|
      gh = FakeGh.new(state: "MERGED")
      closure = FakeClosure.new
      intake = FakeIntake.new
      intake.error = RuntimeError.new("intake offline")
      watcher, store = build_watcher(
        gh: gh, task_closure: closure, merge_intake: intake,
        poll_interval_sec: 60
      )
      row = row_for(tasks.first)
      watcher.observe([ row ], now: T0)

      result = watcher.tick(now: T0).first
      assert_equal :deferred, result.fetch(:status)
      persisted = store.load(identity_for(tasks.first.project_root))
                       .fetch("candidates").values.first
      assert_equal "merged", persisted.dig("remote", "state")
      assert_equal "failed", persisted.dig("architecture", "status")
      assert_match(/intake offline/, persisted.dig("architecture", "last_error"))
      assert_equal "pending", persisted.dig("archive", "status")
      assert_empty closure.calls

      intake.error = nil
      restarted = build_watcher(
        gh: gh, task_closure: closure, merge_intake: intake,
        store: store, poll_interval_sec: 60
      ).first
      restarted.observe([ row ], now: T0 + 61)
      assert_equal :archived, restarted.tick(now: T0 + 61).first.fetch(:status)
      assert_equal 1, gh.fact_calls.length
    end
  end

  def test_restart_after_architecture_acceptance_uses_durable_phase_receipts
    with_merge_project(stages: [ "6-review" ]) do |tasks, _home|
      gh = FakeGh.new(state: "MERGED")
      closure = FakeClosure.new
      closure.error = Interrupt.new("simulated daemon stop before archive")
      intake = FakeIntake.new
      watcher, store = build_watcher(
        gh: gh, task_closure: closure, merge_intake: intake
      )
      row = row_for(tasks.first)
      watcher.observe([ row ], now: T0)

      assert_raises(Interrupt) { watcher.tick(now: T0) }
      persisted = store.load(identity_for(tasks.first.project_root))
                       .fetch("candidates").values.first
      assert_equal "merged", persisted.dig("remote", "state")
      assert_equal "accepted", persisted.dig("architecture", "status")
      assert_equal "pending", persisted.dig("archive", "status")

      closure.error = nil
      restarted = build_watcher(
        gh: gh, task_closure: closure, merge_intake: intake, store: store
      ).first
      restarted.observe([ row ], now: T0 + 1)
      assert_equal :archived, restarted.tick(now: T0 + 1).first.fetch(:status)

      assert_equal 1, gh.fact_calls.length,
                   "durable merge facts must prevent a restart repoll"
      assert_equal 1, intake.calls.length,
                   "durable intake acceptance must prevent duplicate intake"
    end
  end

  def test_failure_backoff_never_drops_and_survives_restart
    with_merge_project(stages: [ "5-open-pr" ]) do |tasks, _home|
      gh = FakeGh.new
      gh.error = Hive::GhError.new("offline")
      watcher, store = build_watcher(gh: gh, poll_interval_sec: 0)
      row = row_for(tasks.first)
      watcher.observe([ row ], now: T0)

      26.times do |index|
        now = T0 + index * 4000
        watcher.tick(now: now)
        watcher = build_watcher(
          gh: gh, store: store, poll_interval_sec: 0
        ).first
        watcher.observe([ row ], now: now)
      end

      state = store.load(identity_for(tasks.first.project_root))
      candidate = state.fetch("candidates").values.first
      assert_equal 26, candidate.dig("retry", "failures")
      assert watcher.watching?(project: "app", slug: tasks.first.slug)
      assert_match(/offline/, candidate.dig("archive", "last_error"))
    end
  end

  def test_persisted_cursor_advances_past_a_failing_candidate
    with_merge_project(stages: [ "5-open-pr", "6-review" ]) do |tasks, _home|
      gh = FakeGh.new(state: "MERGED")
      closure = FakeClosure.new
      closure.error = Hive::TaskClosure::VerificationFailed.new("unsafe first")
      watcher, store = build_watcher(
        gh: gh, task_closure: closure, poll_interval_sec: 0
      )
      watcher.observe(tasks.map { |task| row_for(task) }, now: T0)

      first = watcher.tick(now: T0).first
      assert_equal :blocked, first.fetch(:status)

      closure.error = nil
      restarted = build_watcher(
        gh: gh, task_closure: closure, store: store, poll_interval_sec: 0
      ).first
      restarted.observe(tasks.map { |task| row_for(task) }, now: T0 + 1)
      second = restarted.tick(now: T0 + 1).first

      assert_equal :archived, second.fetch(:status)
      refute_equal first.fetch(:slug), second.fetch(:slug)
    end
  end

  def test_head_mismatch_and_generation_change_fail_closed
    with_merge_project(stages: [ "5-open-pr" ]) do |tasks, _home|
      task = tasks.first
      gh = FakeGh.new(state: "MERGED")
      gh.head_oid = "c" * 40
      closure = FakeClosure.new
      watcher, store = build_watcher(gh: gh, task_closure: closure)
      watcher.observe([ row_for(task) ], now: T0)

      mismatch = watcher.tick(now: T0).first
      assert_equal :blocked, mismatch.fetch(:status)
      assert_empty closure.calls
      candidate = store.load(identity_for(task.project_root)).fetch("candidates").values.first
      assert_equal "delivered_elsewhere", candidate.dig("remote", "state")

      gh.head_oid = "b" * 40
      Hive::Markers.set(task.state_file, :error, "reason" => "changed")
      watcher.observe([ row_for(task) ], now: T0 + 301)
      generation = watcher.tick(now: T0 + 301).first
      refute_nil generation
      assert_includes %i[merged archived], generation.fetch(:status) if
        generation.fetch(:status) != :superseded
      assert store.load(identity_for(task.project_root)).fetch("candidates").values.any? do |item|
        item.dig("archive", "status") == "superseded"
      end
    end
  end

  def test_merged_candidate_without_an_immutable_head_binding_remains_ambiguous
    with_merge_project(stages: [ "6-review" ]) do |tasks, _home|
      task = tasks.first
      remove_pr_head(task)
      gh = FakeGh.new(state: "MERGED")
      closure = FakeClosure.new
      watcher, store = build_watcher(gh: gh, task_closure: closure)
      watcher.observe([ row_for(task) ], now: T0)

      result = watcher.tick(now: T0).first

      assert_equal :blocked, result.fetch(:status)
      assert_empty closure.calls
      candidate = store.load(identity_for(task.project_root)).fetch("candidates").values.first
      assert_equal "ambiguous", candidate.dig("remote", "state")
      assert_equal "blocked", candidate.dig("archive", "status")
      assert_match(/immutable local PR head binding/,
                   candidate.dig("archive", "last_error"))
    end
  end

  def test_owned_task_worktree_supplies_head_binding_for_older_pr_metadata
    with_merge_project(stages: [ "6-review" ]) do |tasks, home|
      task = tasks.first
      remove_pr_head(task)
      worktree = File.join(home, "worktrees", task.slug)
      FileUtils.mkdir_p(File.dirname(worktree))
      run!(
        "git", "-C", task.project_root, "worktree", "add",
        "-b", task.slug, worktree, "main", "--quiet"
      )
      File.write(
        File.join(task.folder, "worktree.yml"),
        { "path" => worktree, "branch" => task.slug }.to_yaml
      )
      head = run!("git", "-C", worktree, "rev-parse", "HEAD").strip
      gh = FakeGh.new(state: "MERGED")
      gh.head_oid = head
      watcher, store = build_watcher(gh: gh, task_closure: Hive::TaskClosure)

      watcher.observe([ row_for(task) ], now: T0)

      candidate = store.load(identity_for(task.project_root)).fetch("candidates").values.first
      assert_equal head, candidate.dig("pull_request", "observed_head")
      with_env("HIVE_ATTEMPT_STORE_ROOT" => File.join(home, "attempts")) do
        assert_equal :archived, watcher.tick(now: T0).first.fetch(:status)
      end
      archived = Hive::TaskResolver.new(task.slug, project_filter: "app").resolve
      assert_equal "9-done", stage_dir(archived)
    end
  end

  def test_repaired_pr_binding_supersedes_ambiguous_candidate
    with_merge_project(stages: [ "6-review" ]) do |tasks, _home|
      task = tasks.first
      remove_pr_head(task)
      gh = FakeGh.new(state: "MERGED")
      watcher, store = build_watcher(gh: gh)
      watcher.observe([ row_for(task) ], now: T0)
      assert_equal :blocked, watcher.tick(now: T0).first.fetch(:status)

      pr_path = File.join(task.folder, "pr.md")
      repaired = File.read(pr_path).sub("---\n\n", "head_oid: #{'b' * 40}\n---\n\n")
      File.write(pr_path, repaired)
      watcher.observe([ row_for(task) ], now: T0 + 1)

      candidates = store.load(identity_for(task.project_root)).fetch("candidates").values
      assert_equal 2, candidates.length
      assert_equal 1, candidates.count { |item| item.dig("archive", "status") == "superseded" }
      assert_equal :archived, watcher.tick(now: T0 + 1).first.fetch(:status)
    end
  end

  def test_pr_binding_change_after_last_observation_cannot_archive
    with_merge_project(stages: [ "7-artifacts" ]) do |tasks, _home|
      task = tasks.first
      gh = FakeGh.new(state: "MERGED")
      closure = FakeClosure.new
      intake = FakeIntake.new
      intake.outcomes = [ :deferred ]
      watcher, store = build_watcher(
        gh: gh, task_closure: closure, merge_intake: intake,
        poll_interval_sec: 0
      )
      watcher.observe([ row_for(task) ], now: T0)
      assert_equal :deferred, watcher.tick(now: T0).first.fetch(:status)

      Hive::Gh.persist_pr_identity!(
        File.join(task.folder, "pr.md"),
        pr_url: "https://github.com/acme/app/pull/99",
        pr_number: 99,
        head_oid: "c" * 40
      )
      result = watcher.tick(now: T0 + 1).first

      assert_equal :superseded, result.fetch(:status)
      assert_empty closure.calls
      candidate = store.load(identity_for(task.project_root))
                       .fetch("candidates").values.first
      assert_equal "superseded", candidate.dig("archive", "status")
    end
  end

  def test_same_generation_pr_binding_drift_persists_a_hold
    with_merge_project(stages: [ "6-review" ]) do |tasks, _home|
      task = tasks.first
      watcher, store = build_watcher
      original = row_for(task)
      watcher.observe([ original ], now: T0)
      changed = original.dup
      changed.pr_url = "https://github.com/acme/app/pull/99"

      watcher.observe([ changed ], now: T0 + 1)

      candidates = store.load(identity_for(task.project_root))
                        .fetch("candidates").values
      held = candidates.find do |candidate|
        candidate.dig("pull_request", "number") == 99
      end
      assert_equal true, held.dig("observation", "held")
      assert_equal "pull_request_binding_changed",
                   held.dig("observation", "hold_reason")
      assert_empty watcher.tick(now: T0 + 1)
    end
  end

  def test_dry_run_records_truth_without_archiving
    with_merge_project(stages: [ "8-finalize" ]) do |tasks, _home|
      gh = FakeGh.new(state: "MERGED")
      closure = FakeClosure.new
      store = Hive::Daemon::PrMergeReconciliationStore.new(dry_run: true)
      watcher, = build_watcher(
        gh: gh, task_closure: closure, store: store, dry_run: true
      )
      watcher.observe([ row_for(tasks.first) ], now: T0)

      assert_equal :dry_run, watcher.tick(now: T0).first.fetch(:status)
      assert_empty closure.calls
      assert_equal "8-finalize", stage_dir(tasks.first)
      refute File.exist?(store.path(tasks.first.hive_state_path))
    end
  end

  def test_real_remote_merge_closure_archives_stage_five_through_eight
    with_merge_project(stages: Hive::Daemon::PrMergeWatcher::SUPPORTED_STAGES) do |tasks, home|
      gh = FakeGh.new(state: "MERGED")
      watcher, = build_watcher(gh: gh, task_closure: Hive::TaskClosure)
      rows = tasks.map { |task| row_for(task) }
      with_env("HIVE_ATTEMPT_STORE_ROOT" => File.join(home, "attempts")) do
        watcher.observe(rows, now: T0)
        tasks.length.times do |index|
          assert_equal :archived, watcher.tick(now: T0 + index).first.fetch(:status)
        end
      end

      tasks.each do |task|
        archived = Hive::TaskResolver.new(task.slug, project_filter: "app").resolve
        assert_equal "9-done", stage_dir(archived)
        receipt = JSON.parse(File.read(File.join(archived.folder, "closure.json")))
        assert_equal "daemon", receipt.dig("confirmed_by", "channel")
        assert_equal "remote_merge", receipt.fetch("authority")
      end
    end
  end

  def test_non_github_identity_is_skipped_and_corrupt_store_blocks_only_observation
    with_merge_project(stages: [ "5-open-pr" ]) do |tasks, _home|
      gh = FakeGh.new
      gh.define_singleton_method(:repository_identity) do |*, **|
        raise "local registrations must not inspect a GitHub remote"
      end
      [ nil, "local:/tmp/app" ].each do |repository_identity|
        lookup = lambda do |_project|
          registration_for(tasks.first.project_root).merge(
            "repository_identity" => repository_identity
          )
        end
        watcher, = build_watcher(gh: gh, config_lookup: lookup)
        result = watcher.observe([ row_for(tasks.first) ], now: T0).first
        assert_equal :skipped, result.fetch(:status)
        assert_match(/not applicable/, result.fetch(:reason))
      end

      watcher, store = build_watcher(gh: FakeGh.new)
      watcher.observe([ row_for(tasks.first) ], now: T0)
      identity = identity_for(tasks.first.project_root)
      File.binwrite(store.path(identity.fetch("hive_state_path")), "{")
      result = watcher.observe([ row_for(tasks.first) ], now: T0 + 1).first
      assert_equal :blocked, result.fetch(:status)
      assert_match(/cannot continue/, result.fetch(:reason))
    end
  end

  def test_github_repository_identity_drift_remains_blocked
    with_merge_project(stages: [ "5-open-pr" ]) do |tasks, _home|
      lookup = lambda do |_project|
        registration_for(tasks.first.project_root).merge(
          "repository_identity" => "github.com/acme/other"
        )
      end
      watcher, = build_watcher(
        gh: FakeGh.new, config_lookup: lookup
      )

      result = watcher.observe([ row_for(tasks.first) ], now: T0).first

      assert_equal :blocked, result.fetch(:status)
      assert_match(/must exactly match github\.com\/acme\/app/,
                   result.fetch(:reason))
    end
  end

  def test_constructor_validation
    assert_raises(ArgumentError) { build_watcher(poll_interval_sec: -1) }
    assert_raises(ArgumentError) { build_watcher(poll_timeout_sec: 0) }
  end

  def test_recovery_fence_tracks_remote_state_and_store_failures_fail_closed
    with_merge_project(stages: [ "5-open-pr" ]) do |tasks, _home|
      watcher, store = build_watcher(gh: FakeGh.new(state: "OPEN"))
      task = tasks.first
      watcher.observe([ row_for(task) ], now: T0)

      assert watcher.recovery_blocked?(project: "app", slug: task.slug)
      assert_equal :open, watcher.tick(now: T0).first.fetch(:status)
      refute watcher.recovery_blocked?(project: "app", slug: task.slug)
      refute watcher.recovery_blocked?(project: "app", slug: "missing")

      store.define_singleton_method(:load) do |_identity|
        raise IOError, "ledger unreadable"
      end
      result = watcher.tick(now: T0 + 1).first
      assert_equal :blocked, result.fetch(:status)
      assert_match(/ledger unreadable/, result.fetch(:reason))
      refute watcher.watching?(project: "app", slug: task.slug)
    end
  end

  def test_terminal_rows_reconcile_candidates_and_terminal_receipts
    with_merge_project(stages: [ "5-open-pr" ]) do |tasks, _home|
      task = tasks.first
      watcher, store = build_watcher
      watcher.observe([ row_for(task) ], now: T0)

      terminal = row_for(task)
      terminal.stage = Hive::Stages::DIRS.last
      watcher.observe([ terminal ], now: T0 + 1)

      candidate = store.load(identity_for(task.project_root))
                       .fetch("candidates").values.first
      assert_equal "blocked", candidate.dig("archive", "status")
      assert_match(/no valid merge closure receipt/,
                   candidate.dig("archive", "last_error"))

      valid = Hive::TaskClosure::ReadResult.new(
        status: "valid",
        receipt: { "receipt_digest" => "d" * 64 },
        error: nil,
        quarantine_path: nil
      )
      with_replaced_singleton_method(
        Hive::TaskClosure, :read, ->(*) { valid }
      ) do
        result = watcher.send(
          :terminal_result,
          task,
          identity_for(task.project_root),
          now: T0
        )
        assert_equal :already_archived, result.fetch(:status)
        assert_equal "d" * 64,
                     result.dig(:archive, "receipt_digest")
      end

      missing = deep_copy(candidate)
      missing["task"]["slug"] = "missing-task"
      assert_nil watcher.send(
        :mark_terminal_candidate,
        missing,
        identity_for(task.project_root),
        now: T0
      )
    end
  end

  def test_remote_and_checkpoint_failures_are_persisted_without_losing_candidate
    with_merge_project(stages: [ "5-open-pr" ]) do |tasks, _home|
      task = tasks.first
      watcher, store = build_watcher
      watcher.observe([ row_for(task) ], now: T0)
      identity = identity_for(task.project_root)
      candidate = store.load(identity).fetch("candidates").values.first

      facts = {
        "state" => "MERGED",
        "merge_oid" => "short",
        "merged_at" => T0.iso8601,
        "head_oid" => candidate.dig("pull_request", "observed_head"),
        "reachable_from_default" => false
      }
      assert_raises(Hive::GhError) do
        watcher.send(:remote_result, facts, candidate, now: T0)
      end

      failed = deep_copy(candidate)
      watcher.send(
        :apply_result!,
        failed,
        { status: :failed, reason: "remote unavailable" },
        now: T0
      )
      assert_equal 1, failed.dig("retry", "failures")
      assert_match(/remote unavailable/, failed.dig("archive", "last_error"))

      missing = deep_copy(candidate)
      missing["key"] = "f" * 64
      assert_raises(Hive::ConcurrentRunError) do
        watcher.send(
          :checkpoint!,
          identity,
          missing,
          { status: :open },
          now: T0
        )
      end
    end
  end

  def test_binding_merge_helpers_preserve_holds_detect_drift_and_learn_head
    with_merge_project(stages: [ "5-open-pr" ]) do |tasks, _home|
      task = tasks.first
      watcher, store = build_watcher
      watcher.observe([ row_for(task) ], now: T0)
      identity = identity_for(task.project_root)
      base = store.load(identity).fetch("candidates").values.first

      held = deep_copy(base)
      held["observation"]["hold_reason"] = "pull_request_binding_changed"
      merged = watcher.send(:merge_observation, held, deep_copy(base))
      assert_equal true, merged.dig("observation", "held")
      assert_equal "pull_request_binding_changed",
                   merged.dig("observation", "hold_reason")

      changed = deep_copy(base)
      changed["pull_request"]["number"] = 99
      changed["pull_request"]["url"] =
        "https://github.com/acme/app/pull/99"
      merged = watcher.send(:merge_observation, deep_copy(base), changed)
      assert_equal "pull_request_binding_changed",
                   merged.dig("observation", "hold_reason")

      without_head = deep_copy(base)
      without_head["pull_request"]["observed_head"] = nil
      learned = watcher.send(
        :merge_observation, without_head, deep_copy(base)
      )
      assert_equal base.dig("pull_request", "observed_head"),
                   learned.dig("pull_request", "observed_head")
      assert_equal "unknown", learned.dig("remote", "state")
      assert_equal "pending", learned.dig("archive", "status")

      changed_head = deep_copy(base)
      changed_head["pull_request"]["observed_head"] = "c" * 40
      assert watcher.send(:binding_drift?, base, changed_head)
      assert_equal "observed_head_changed",
                   watcher.send(:binding_drift_reason, base, changed_head)

      assert_equal base.dig("pull_request", "url"),
                   watcher.send(:read_pr_url, task)
      assert_nil watcher.send(:timestamp_for, "not-a-time")
    end
  end

  private

  def deep_copy(value)
    Marshal.load(Marshal.dump(value))
  end

  def build_watcher(gh: FakeGh.new, task_closure: FakeClosure.new,
                    merge_intake: nil, store: nil, poll_interval_sec: 0,
                    poll_timeout_sec: 7, config_lookup: nil, dry_run: false)
    store ||= Hive::Daemon::PrMergeReconciliationStore.new(
      dry_run: dry_run, backoff_base_sec: 1, backoff_max_sec: 3600
    )
    watcher = Hive::Daemon::PrMergeWatcher.new(
      poll_interval_sec: poll_interval_sec,
      poll_timeout_sec: poll_timeout_sec,
      merge_intake: merge_intake,
      store: store,
      gh: gh,
      config_lookup: config_lookup || Hive::Config.method(:find_project),
      task_closure: task_closure,
      dry_run: dry_run
    )
    [ watcher, store ]
  end

  def row_for(task)
    marker = Hive::Markers.current(task.state_file)
    Row.new(
      project: "app",
      slug: task.slug,
      id: task.id,
      stage: stage_dir(task),
      workflow: task.workflow.id.to_s,
      marker: marker.name.to_s,
      folder: task.folder,
      state_file_mtime: File.mtime(task.state_file),
      pr_url: Hive::Gh.pr_frontmatter(File.join(task.folder, "pr.md"))["pr_url"],
      blocked: false,
      admission_error: nil
    )
  end

  def identity_for(project)
    registration = registration_for(project)
    {
      "registration" => "app",
      "project_path" => project,
      "hive_state_path" => registration.fetch("hive_state_path"),
      "host" => "github.com",
      "repository" => "acme/app",
      "default_branch" => "main"
    }
  end

  def registration_for(project)
    {
      "name" => "app",
      "path" => project,
      "hive_state_path" => File.join(project, ".hive-state"),
      "repository_identity" => "github.com/acme/app"
    }
  end

  def stage_dir(task)
    "#{task.stage_index}-#{task.stage_name}"
  end

  def remove_pr_head(task)
    path = File.join(task.folder, "pr.md")
    File.write(path, File.read(path).sub(/^head_oid:.*\n/, ""))
  end

  def with_merge_project(stages:)
    with_tmp_global_config do |home|
      project = File.join(home, "app")
      FileUtils.mkdir_p(project)
      run!("git", "-C", project, "init", "-b", "main", "--quiet")
      run!("git", "-C", project, "config", "user.email", "test@example.com")
      run!("git", "-C", project, "config", "user.name", "Test")
      run!("git", "-C", project, "config", "commit.gpgsign", "false")
      File.write(File.join(project, "README.md"), "app\n")
      run!("git", "-C", project, "add", "README.md")
      run!("git", "-C", project, "commit", "-m", "initial", "--quiet")
      Hive::GitOps.new(project).hive_state_init
      hive_state = File.join(project, ".hive-state")
      File.write(
        File.join(hive_state, "config.yml"),
        {
          "default_branch" => "main",
          "default_workflow" => "coding",
          "worktree_root" => File.join(home, "worktrees")
        }.to_yaml
      )
      tasks = stages.each_with_index.map do |stage, index|
        slug = "merge-task-#{index}"
        folder = File.join(hive_state, "stages", stage, slug)
        FileUtils.mkdir_p(folder)
        Hive::TaskMeta.write(folder, id: index + 1, slug: slug, display_name: "Merge #{index}")
        task = Hive::Task.new(folder)
        File.write(task.state_file, "# #{slug}\n")
        File.write(
          File.join(folder, "pr.md"),
          <<~MD
            ---
            pr_url: https://github.com/acme/app/pull/#{index + 40}
            head_oid: #{"b" * 40}
            ---

            Pull request
          MD
        )
        Hive::Markers.set(task.state_file, index.odd? ? :error : :complete,
                          "reason" => "dogfood")
        task
      end
      run!("git", "-C", hive_state, "add", ".")
      run!("git", "-C", hive_state, "commit", "-m", "seed merge tasks", "--quiet")
      File.write(
        File.join(home, "config.yml"),
        { "registered_projects" => [ registration_for(project) ] }.to_yaml
      )
      yield tasks, home
    end
  end
end
