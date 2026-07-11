require "test_helper"
require "hive/config"
require "hive/daemon/refactor_patrol_merge_reconciler"
require "hive/refactor_patrol/job_store"

class HiveDaemonRefactorPatrolMergeReconcilerTest < Minitest::Test
  include HiveTestHelper

  T0 = Time.utc(2026, 7, 10, 12, 0, 0)

  class FakeGh
    attr_accessor :repository, :pages, :details, :failing_cursor,
                  :historical_count, :active_result_count
    attr_reader :page_calls

    def initialize(repository: "acme/demo")
      @repository = repository
      @pages = {}
      @details = {}
      @page_calls = []
      @historical_count = 0
      @active_result_count = 0
    end

    def repo_name_with_owner(*)
      repository
    end

    def merged_prs_page(repository:, default_branch:, cursor:, merged_since:, per_page:, **)
      @page_calls << {
        repository: repository,
        default_branch: default_branch,
        cursor: cursor,
        merged_since: merged_since,
        per_page: per_page
      }
      if merged_since.nil? && historical_count > 1000
        raise Hive::GhError, "historical result set exceeds traversal cap"
      end
      if active_result_count > 1000
        raise Hive::GhError, "active overlap exceeds 1,000-result traversal cap"
      end
      raise Hive::GhError, "page failed" if failing_cursor && cursor == failing_cursor

      Marshal.load(Marshal.dump(pages.fetch(cursor)))
    end

    def merged_pr_details(pr, **)
      number = pr.to_s[%r{/pull/(\d+)\z}, 1]&.to_i || pr.to_i
      value = details.fetch(number)
      raise value if value.is_a?(Exception)

      Marshal.load(Marshal.dump(value))
    end
  end

  def test_first_enable_seeds_paginated_baseline_without_historical_jobs
    with_tmp_dir do |dir|
      gh = FakeGh.new
      gh.historical_count = 2000
      gh.pages = {
        nil => page([ summary(99, at: T0 - 7200), summary(1, at: T0 - 120) ], next_cursor: "page-2"),
        "page-2" => page([ summary(2, at: T0 - 60) ])
      }

      result = reconciler(dir, gh).tick(now: T0).fetch(0)
      state = JSON.parse(File.read(state_path(dir)))

      assert_equal :seeded, result.fetch(:status)
      assert_equal 2, gh.page_calls.size
      assert_equal T0 - 3600, gh.page_calls.first.fetch(:merged_since)
      assert_equal 2, state.dig("high_water", "pr_number")
      refute_includes state.fetch("overlap_occurrences").map { |item| item.fetch("pr_number") }, 99
      assert_equal "acme/demo", state.fetch("repository")
      assert_equal "main", state.fetch("default_branch")
      assert_empty job_store(dir).jobs
      assert_empty Dir.glob(File.join(dir, ".hive-state", "refactor_patrol", "v2", "manifests", "*.json"))
    end
  end

  def test_first_enable_blocks_when_active_overlap_itself_exceeds_search_cap
    with_tmp_dir do |dir|
      gh = FakeGh.new
      gh.active_result_count = 1001
      gh.pages = { nil => page([]) }

      result = reconciler(dir, gh).tick(now: T0).fetch(0)

      assert_equal :blocked, result.fetch(:status)
      assert_match(/1,000-result traversal cap/, result.fetch(:reason))
      refute File.exist?(state_path(dir))
      assert_empty job_store(dir).jobs
    end
  end

  def test_catch_up_polling_is_bounded_by_its_own_cadence
    with_tmp_dir do |dir|
      gh = FakeGh.new
      gh.pages = { nil => page([ summary(1, at: T0) ]) }
      entry = { "name" => "demo", "path" => dir, "hive_state_path" => File.join(dir, ".hive-state") }
      intake = Hive::Daemon::RefactorPatrolMergeReconciler.new(
        registry: -> { [ entry ] },
        config_loader: ->(_path) { enabled_cfg },
        gh: gh,
        poll_interval_sec: 300
      )

      assert_equal :seeded, intake.tick(now: T0).fetch(0).fetch(:status)
      assert_empty intake.tick(now: T0 + 60)
      assert_equal 1, gh.page_calls.size
      assert_equal :ok, intake.tick(now: T0 + 301).fetch(0).fetch(:status)
      assert_equal 2, gh.page_calls.size
    end
  end

  def test_catch_up_handles_equal_timestamps_page_reordering_and_restart_without_duplicates
    with_tmp_dir do |dir|
      gh = FakeGh.new
      gh.pages = { nil => page([ summary(9, at: T0) ]) }
      reconciler(dir, gh).tick(now: T0)

      gh.details = {
        8 => details(8, at: T0),
        10 => details(10, at: T0 + 60)
      }
      gh.pages = {
        nil => page([ summary(10, at: T0 + 60), summary(9, at: T0) ], next_cursor: "page-2"),
        "page-2" => page([ summary(8, at: T0) ])
      }

      first = reconciler(dir, gh).tick(now: T0 + 120).fetch(0)
      restarted = reconciler(dir, gh).tick(now: T0 + 180).fetch(0)

      assert_equal :ok, first.fetch(:status)
      assert_equal [ 8, 10 ], first.fetch(:enqueued_prs)
      assert_equal :ok, restarted.fetch(:status)
      assert_empty restarted.fetch(:enqueued_prs)
      assert_equal [ 8, 10 ], job_store(dir).jobs.map { |job| job.dig("source", "number") }.sort
      state = JSON.parse(File.read(state_path(dir)))
      assert_equal 10, state.dig("high_water", "pr_number")
      assert_includes state.fetch("overlap_occurrences").map { |item| item.fetch("pr_number") }, 8,
                      "an unseen lower tuple at the same timestamp must be remembered and ingested"
    end
  end

  def test_immediate_and_catch_up_producers_converge_on_one_manifest_and_job
    with_tmp_dir do |dir|
      gh = FakeGh.new
      gh.details = { 2 => details(2, at: T0) }
      gh.pages = { nil => page([ summary(2, at: T0) ]) }
      intake = reconciler(dir, gh)

      immediate = intake.ingest(
        project: "demo",
        pr: "https://github.com/acme/demo/pull/2",
        now: T0
      )
      catch_up = intake.tick(now: T0 + 60).fetch(0)

      assert_equal immediate.fetch("job_id"), job_store(dir).jobs.fetch(0).fetch("job_id")
      assert_equal :seeded, catch_up.fetch(:status)
      assert_equal 1, job_store(dir).jobs.size
      assert_equal 1, Dir.glob(File.join(dir, ".hive-state", "refactor_patrol", "v2", "manifests", "*.json")).size
    end
  end

  def test_intake_snapshots_the_complete_action_policy
    with_tmp_dir do |dir|
      gh = FakeGh.new
      gh.details = { 2 => details(2, at: T0) }
      cfg = enabled_cfg
      cfg["refactor_patrol"]["auto_fix"].merge!("enabled" => true, "agent" => "codex")
      cfg["refactor_patrol"]["issue_filing"].merge!(
        "enabled" => true, "min_leverage_score" => 0.7
      )
      cfg["refactor_patrol"]["caps"]["max_files"] = 3
      cfg["refactor_patrol"]["commands"]["test"] = "bin/test"

      reconciler(dir, gh, cfg: cfg).ingest(
        project: "demo", pr: "https://github.com/acme/demo/pull/2", now: T0
      )
      policy = job_store(dir).jobs.fetch(0).fetch("policy")

      assert_equal true, policy.fetch("auto_fix")
      assert_equal true, policy.fetch("issue_filing")
      assert_equal "codex", policy.dig("action", "auto_fix_agent")
      assert_equal 3, policy.dig("action", "caps", "max_files")
      assert_equal "bin/test", policy.dig("action", "commands", "test")
      assert_equal 0.7, policy.dig("action", "issue_min_leverage_score")
      assert_match(/\A[a-f0-9]{64}\z/, policy.fetch("epoch"))
    end
  end

  def test_pagination_failure_holds_checkpoint_and_publishes_no_new_job
    with_tmp_dir do |dir|
      gh = FakeGh.new
      gh.pages = { nil => page([ summary(1, at: T0) ]) }
      reconciler(dir, gh).tick(now: T0)
      before = File.binread(state_path(dir))

      gh.pages = { nil => page([ summary(2, at: T0 + 60) ], next_cursor: "page-2") }
      gh.failing_cursor = "page-2"
      result = reconciler(dir, gh).tick(now: T0 + 120).fetch(0)

      assert_equal :blocked, result.fetch(:status)
      assert_match(/page failed/, result.fetch(:reason))
      assert_equal before, File.binread(state_path(dir))
      assert_empty job_store(dir).jobs
    end
  end

  def test_manifest_failure_and_crash_before_checkpoint_replay_durable_predecessors
    with_tmp_dir do |dir|
      gh = FakeGh.new
      gh.pages = { nil => page([ summary(1, at: T0) ]) }
      reconciler(dir, gh).tick(now: T0)
      before = File.binread(state_path(dir))

      gh.pages = { nil => page([ summary(2, at: T0 + 60), summary(3, at: T0 + 120) ]) }
      gh.details = {
        2 => details(2, at: T0 + 60),
        3 => Hive::GhError.new("manifest unavailable")
      }
      blocked = reconciler(dir, gh).tick(now: T0 + 180).fetch(0)

      assert_equal :blocked, blocked.fetch(:status)
      assert_equal [ 2 ], job_store(dir).jobs.map { |job| job.dig("source", "number") }
      assert_equal before, File.binread(state_path(dir)), "partial intake must not advance high-water"

      gh.details[3] = details(3, at: T0 + 120)
      recovered = reconciler(dir, gh).tick(now: T0 + 240).fetch(0)

      assert_equal :ok, recovered.fetch(:status)
      assert_equal [ 2, 3 ], job_store(dir).jobs.map { |job| job.dig("source", "number") }.sort
      assert_equal 3, JSON.parse(File.read(state_path(dir))).dig("high_water", "pr_number")
    end
  end

  def test_checkpoint_write_failure_replays_durable_jobs_without_duplicate
    with_tmp_dir do |dir|
      gh = FakeGh.new
      gh.pages = { nil => page([ summary(1, at: T0) ]) }
      reconciler(dir, gh).tick(now: T0)
      before = File.binread(state_path(dir))
      gh.pages = { nil => page([ summary(2, at: T0 + 60) ]) }
      gh.details = { 2 => details(2, at: T0 + 60) }
      original_write = Hive::AtomicFile.method(:write)
      checkpoint_path = state_path(dir)
      blocked = nil

      with_replaced_singleton_method(Hive::AtomicFile, :write, lambda { |path, *args, **kwargs|
        raise Errno::ENOSPC, path if path == checkpoint_path

        original_write.call(path, *args, **kwargs)
      }) do
        blocked = reconciler(dir, gh).tick(now: T0 + 120).fetch(0)
      end

      assert_equal :blocked, blocked.fetch(:status)
      assert_equal before, File.binread(state_path(dir))
      assert_equal [ 2 ], job_store(dir).jobs.map { |job| job.dig("source", "number") }

      recovered = reconciler(dir, gh).tick(now: T0 + 180).fetch(0)
      assert_equal :ok, recovered.fetch(:status)
      assert_equal 1, job_store(dir).jobs.size
      assert_equal 2, JSON.parse(File.read(state_path(dir))).dig("high_water", "pr_number")
    end
  end

  def test_repository_or_default_branch_change_blocks_without_rebaselining
    with_tmp_dir do |dir|
      gh = FakeGh.new
      gh.pages = { nil => page([ summary(1, at: T0) ]) }
      cfg = enabled_cfg
      reconciler(dir, gh, cfg: cfg).tick(now: T0)
      before = File.binread(state_path(dir))

      registration = reconciler(dir, gh, cfg: cfg, name: "renamed").tick(now: T0 + 30).fetch(0)
      assert_equal :blocked, registration.fetch(:status)
      assert_match(/registration identity changed/, registration.fetch(:reason))
      assert_equal before, File.binread(state_path(dir))

      gh.repository = "acme/renamed"
      renamed = reconciler(dir, gh, cfg: cfg).tick(now: T0 + 60).fetch(0)
      assert_equal :blocked, renamed.fetch(:status)
      assert_match(/repository identity changed/, renamed.fetch(:reason))
      assert_equal before, File.binread(state_path(dir))
      refute_empty quarantine_paths(dir)

      gh.repository = "acme/demo"
      cfg["default_branch"] = "trunk"
      branch = reconciler(dir, gh, cfg: cfg).tick(now: T0 + 120).fetch(0)
      assert_equal :blocked, branch.fetch(:status)
      assert_match(/default branch changed/, branch.fetch(:reason))
      assert_equal before, File.binread(state_path(dir))
    end
  end

  def test_high_water_orders_timestamp_offsets_as_utc_instants
    with_tmp_dir do |dir|
      gh = FakeGh.new
      first = summary(9, at: T0).merge("merged_at" => "2026-07-10T13:00:00+01:00")
      gh.pages = { nil => page([ first ]) }
      reconciler(dir, gh).tick(now: T0)
      assert_equal "2026-07-10T12:00:00Z",
                   JSON.parse(File.read(state_path(dir))).dig("high_water", "merged_at")

      gh.pages = { nil => page([ summary(10, at: T0), first ]) }
      gh.details = { 10 => details(10, at: T0) }
      result = reconciler(dir, gh).tick(now: T0 + 60).fetch(0)

      assert_equal [ 10 ], result.fetch(:enqueued_prs)
      assert_equal 10, JSON.parse(File.read(state_path(dir))).dig("high_water", "pr_number")
    end
  end

  def test_corrupt_or_newer_checkpoint_blocks_visibly_without_rewrite
    with_tmp_dir do |dir|
      path = state_path(dir)
      FileUtils.mkdir_p(File.dirname(path))
      [ "{", JSON.generate("schema" => "hive-refactor-patrol-reconciler", "schema_version" => 99) ].each do |bytes|
        File.binwrite(path, bytes)
        gh = FakeGh.new
        gh.pages = { nil => page([]) }

        result = reconciler(dir, gh).tick(now: T0).fetch(0)

        assert_equal :blocked, result.fetch(:status)
        assert_equal bytes, File.binread(path)
      end
    end
  end

  private

  def reconciler(dir, gh, cfg: enabled_cfg, name: "demo")
    entry = { "name" => name, "path" => dir, "hive_state_path" => File.join(dir, ".hive-state") }
    Hive::Daemon::RefactorPatrolMergeReconciler.new(
      registry: -> { [ entry ] },
      config_loader: ->(_path) { cfg },
      gh: gh,
      overlap_sec: 3600,
      page_size: 2,
      poll_interval_sec: 0
    )
  end

  def enabled_cfg
    Hive::Config.deep_merge(
      Hive::Config.deep_dup(Hive::Config::DEFAULTS),
      {
        "default_branch" => "main",
        "daemon" => { "enabled" => true },
        "refactor_patrol" => {
          "enabled" => true,
          "auto_fix" => { "enabled" => false },
          "issue_filing" => { "enabled" => false }
        }
      }
    )
  end

  def page(items, next_cursor: nil)
    {
      "items" => items,
      "next_cursor" => next_cursor,
      "has_next_page" => !next_cursor.nil?,
      "complete" => true
    }
  end

  def summary(number, at:)
    {
      "number" => number,
      "url" => "https://github.com/acme/demo/pull/#{number}",
      "repository" => "acme/demo",
      "base_branch" => "main",
      "merge_sha" => format("%040x", number),
      "merged_at" => at.utc.iso8601
    }
  end

  def details(number, at:)
    summary(number, at: at).merge(
      "state" => "MERGED",
      "base_sha" => "a" * 40,
      "changed_files" => 1,
      "files" => [ { "path" => "lib/pr_#{number}.rb", "status" => "modified" } ]
    )
  end

  def state_path(dir)
    File.join(dir, ".hive-state", "refactor_patrol", "v2", "reconciler.json")
  end

  def job_store(dir)
    Hive::RefactorPatrol::JobStore.new(dir)
  end

  def quarantine_paths(dir)
    Dir.glob(File.join(dir, ".hive-state", "refactor_patrol", "v2", "quarantine", "reconciler", "*.json"))
  end
end
