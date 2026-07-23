require "test_helper"
require "hive/config"
require "hive/daemon/refactor_patrol_merge_reconciler"
require "hive/refactor_patrol/job_store"

class HiveDaemonRefactorPatrolMergeReconcilerTest < Minitest::Test
  include HiveTestHelper

  T0 = Time.utc(2026, 7, 10, 12, 0, 0)

  class FakeGh
    attr_accessor :repository, :host, :pages, :details, :failing_cursor,
                  :historical_count, :active_result_count
    attr_reader :page_calls, :detail_calls, :identity_calls

    def initialize(repository: "acme/demo")
      @repository = repository
      @host = "github.com"
      @pages = {}
      @details = {}
      @page_calls = []
      @detail_calls = []
      @identity_calls = []
      @historical_count = 0
      @active_result_count = 0
    end

    def repository_identity(*, timeout_sec: nil, **)
      @identity_calls << timeout_sec
      { "repository" => repository, "host" => host }
    end

    def merged_prs_page(repository:, default_branch:, cursor:, merged_since:, per_page:,
                        merged_until: nil, timeout_sec: nil, **)
      @page_calls << {
        repository: repository,
        default_branch: default_branch,
        cursor: cursor,
        merged_since: merged_since,
        merged_until: merged_until,
        per_page: per_page,
        timeout_sec: timeout_sec
      }
      if merged_since.nil? && historical_count > 1000
        raise Hive::GhError, "historical result set exceeds traversal cap"
      end
      if active_result_count > 1000
        raise Hive::GhError, "active overlap exceeds 1,000-result traversal cap"
      end
      raise Hive::GhError, "page failed" if failing_cursor && cursor == failing_cursor

      result = Marshal.load(Marshal.dump(pages.fetch(cursor)))
      result["total_count"] ||= frozen_result_count(merged_since, merged_until)
      result
    end

    def merged_pr_details(pr, timeout_sec: nil, **)
      number = pr.to_s[%r{/pull/(\d+)\z}, 1]&.to_i || pr.to_i
      @detail_calls << { number: number, timeout_sec: timeout_sec }
      value = details.fetch(number)
      raise value if value.is_a?(Exception)

      Marshal.load(Marshal.dump(value))
    end

    private

    def frozen_result_count(merged_since, merged_until)
      lower = merged_since && (merged_since.is_a?(Time) ? merged_since.utc : Time.iso8601(merged_since.to_s).utc)
      upper = merged_until && (merged_until.is_a?(Time) ? merged_until.utc : Time.iso8601(merged_until.to_s).utc)
      pages.values.flat_map { |candidate| candidate.fetch("items") }
           .select do |item|
             merged_at = Time.iso8601(item.fetch("merged_at")).utc
             (!lower || merged_at >= lower) && (!upper || merged_at <= upper)
           end
           .uniq { |item| [ item["repository"], item["number"], item["merge_sha"] ] }
           .length
    end
  end

  class FakeMonotonic
    attr_reader :now

    def initialize(now = 0.0)
      @now = now
    end

    def call
      now
    end

    def advance(seconds)
      @now += seconds
    end
  end

  class MultiProjectGh
    attr_accessor :slow_repository
    attr_reader :page_calls

    def initialize(identities:, clock:)
      @identities = identities
      @clock = clock
      @page_calls = []
    end

    def repository_identity(path, **)
      { "repository" => @identities.fetch(path), "host" => "github.com" }
    end

    def merged_prs_page(repository:, timeout_sec:, **)
      @page_calls << { repository: repository, timeout_sec: timeout_sec }
      if repository == slow_repository
        @clock.advance(timeout_sec)
        raise Hive::GhError, "simulated outage"
      end

      {
        "items" => [], "next_cursor" => nil,
        "has_next_page" => false, "total_count" => 0, "complete" => true
      }
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
      assert_equal "github.com", state.fetch("host")
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
        github_gateway: gh,
        poll_interval_sec: 300
      )

      assert_equal :seeded, intake.tick(now: T0).fetch(0).fetch(:status)
      assert_empty intake.tick(now: T0 + 60)
      assert_equal 1, gh.page_calls.size
      assert_equal :ok, intake.tick(now: T0 + 301).fetch(0).fetch(:status)
      assert_equal 2, gh.page_calls.size
    end
  end

  def test_paginated_cursor_is_durable_and_restart_resumes_without_refetching_first_page
    with_tmp_dir do |dir|
      clock = FakeMonotonic.new
      gh = FakeGh.new
      gh.pages = {
        nil => page([ summary(1, at: T0) ], next_cursor: "page-2"),
        "page-2" => page([ summary(2, at: T0) ])
      }
      original_page = gh.method(:merged_prs_page)
      consume_first_budget = true
      gh.define_singleton_method(:merged_prs_page) do |**kwargs|
        result = original_page.call(**kwargs)
        if consume_first_budget
          clock.advance(kwargs.fetch(:timeout_sec))
          consume_first_budget = false
        end
        result
      end
      options = {
        tick_budget_sec: 1, max_call_timeout_sec: 1,
        monotonic_clock: clock
      }

      partial = reconciler(dir, gh, **options).tick(now: T0).fetch(0)
      progress = JSON.parse(File.read(progress_path(dir)))

      assert_equal :partial, partial.fetch(:status)
      assert_equal "page-2", progress.dig("scan", "cursor")
      assert_equal [ 1 ], progress.dig("scan", "items").map { |item| item.fetch("number") }
      refute File.exist?(state_path(dir))

      resumed = reconciler(dir, gh, **options).tick(now: T0 + 1).fetch(0)

      assert_equal :seeded, resumed.fetch(:status)
      assert_equal [ nil, "page-2" ], gh.page_calls.map { |call| call.fetch(:cursor) }
      assert_equal 2, JSON.parse(File.read(state_path(dir))).dig("high_water", "pr_number")
      refute File.exist?(progress_path(dir))
    end
  end

  def test_baseline_freezes_upper_bound_and_ingests_a_merge_arriving_between_pages_next_scan
    with_tmp_dir do |dir|
      clock = FakeMonotonic.new
      gh = FakeGh.new
      gh.pages = {
        nil => page(
          [ summary(1, at: T0 - 30), summary(2, at: T0 - 20) ],
          next_cursor: "page-2"
        ),
        "page-2" => page([ summary(3, at: T0 - 10) ])
      }
      original_page = gh.method(:merged_prs_page)
      consume_first_budget = true
      gh.define_singleton_method(:merged_prs_page) do |**kwargs|
        result = original_page.call(**kwargs)
        if consume_first_budget
          clock.advance(kwargs.fetch(:timeout_sec))
          consume_first_budget = false
        end
        result
      end
      options = {
        tick_budget_sec: 1, max_call_timeout_sec: 1,
        monotonic_clock: clock
      }
      intake = reconciler(dir, gh, **options)

      assert_equal :partial, intake.tick(now: T0).fetch(0).fetch(:status)
      assert_equal T0, gh.page_calls.first.fetch(:merged_until)

      gh.pages["page-2"] = page([
        summary(3, at: T0 - 10), summary(4, at: T0 + 1)
      ])
      seeded = intake.tick(now: T0 + 1).fetch(0)
      assert_equal :seeded, seeded.fetch(:status)
      assert_equal 3, JSON.parse(File.read(state_path(dir))).dig("high_water", "pr_number")
      assert_empty job_store(dir).jobs
      assert_equal T0, gh.page_calls.fetch(1).fetch(:merged_until),
                   "a resumed baseline must retain its original upper bound"

      gh.pages = { nil => page([ summary(4, at: T0 + 1) ]) }
      gh.details = { 4 => details(4, at: T0 + 1) }
      caught_up = intake.tick(now: T0 + 2).fetch(0)
      assert_equal :ok, caught_up.fetch(:status)
      assert_equal [ 4 ], caught_up.fetch(:enqueued_prs)
      assert_equal [ 4 ], job_store(dir).jobs.map { |job| job.dig("source", "number") }
    end
  end

  def test_paginated_scan_restarts_and_converges_if_frozen_result_count_changes
    with_tmp_dir do |dir|
      clock = FakeMonotonic.new
      gh = FakeGh.new
      gh.pages = {
        nil => page([ summary(1, at: T0 - 20) ], next_cursor: "page-2"),
        "page-2" => page([ summary(2, at: T0 - 10) ])
      }
      original_page = gh.method(:merged_prs_page)
      consume_first_budget = true
      gh.define_singleton_method(:merged_prs_page) do |**kwargs|
        result = original_page.call(**kwargs)
        if consume_first_budget
          clock.advance(kwargs.fetch(:timeout_sec))
          consume_first_budget = false
        end
        result
      end
      options = {
        tick_budget_sec: 1, max_call_timeout_sec: 1,
        monotonic_clock: clock, jitter: -> { 0.0 }
      }

      assert_equal :partial, reconciler(dir, gh, **options).tick(now: T0).fetch(0).fetch(:status)
      gh.pages["page-2"] = page([
        summary(2, at: T0 - 10), summary(3, at: T0 - 5),
        summary(4, at: T0 + 1)
      ])

      result = reconciler(dir, gh, **options).tick(now: T0 + 1).fetch(0)
      assert_equal :seeded, result.fetch(:status)
      assert_equal [ nil, "page-2", nil, "page-2" ],
                   gh.page_calls.map { |call| call.fetch(:cursor) }
      assert gh.page_calls.all? { |call| call.fetch(:merged_until) == T0 },
             "a restarted baseline must retain its original upper bound"
      assert_equal 3, JSON.parse(File.read(state_path(dir))).dig("high_water", "pr_number")
      refute File.exist?(progress_path(dir))
    end
  end

  def test_github_failures_back_off_exponentially_and_restart_honors_not_before
    with_tmp_dir do |dir|
      clock = FakeMonotonic.new
      gh = FakeGh.new
      gh.pages = { nil => page([]) }
      reconciler(dir, gh, jitter: -> { 0.0 }, monotonic_clock: clock).tick(now: T0)
      original_page = gh.method(:merged_prs_page)
      gh.define_singleton_method(:merged_prs_page) do |**kwargs|
        original_page.call(**kwargs)
        raise Hive::GhError, "GitHub unavailable"
      end

      first = reconciler(
        dir, gh, jitter: -> { 0.0 }, monotonic_clock: clock
      ).tick(now: T0 + 1).fetch(0)
      retry_state = JSON.parse(File.read(progress_path(dir))).fetch("retry")

      assert_equal :blocked, first.fetch(:status)
      assert_equal 1, retry_state.fetch("failures")
      assert_equal T0 + 3.5, Time.iso8601(retry_state.fetch("not_before"))
      calls_after_failure = gh.page_calls.length

      restarted = reconciler(
        dir, gh, jitter: -> { 0.0 }, monotonic_clock: clock
      )
      waiting = restarted.tick(now: T0 + 2).fetch(0)
      assert_equal :backoff, waiting.fetch(:status)
      assert_equal calls_after_failure, gh.page_calls.length

      second = restarted.tick(now: T0 + 4).fetch(0)
      retry_state = JSON.parse(File.read(progress_path(dir))).fetch("retry")
      assert_equal :blocked, second.fetch(:status)
      assert_equal 2, retry_state.fetch("failures")
      assert_equal T0 + 9, Time.iso8601(retry_state.fetch("not_before"))
    end
  end

  def test_github_backoff_starts_when_the_slow_failure_returns
    with_tmp_dir do |dir|
      clock = FakeMonotonic.new
      gh = FakeGh.new
      gh.pages = { nil => page([]) }
      reconciler(
        dir, gh, monotonic_clock: clock,
        tick_budget_sec: 5, max_call_timeout_sec: 5,
        jitter: -> { 0.0 }
      ).tick(now: T0)
      original_page = gh.method(:merged_prs_page)
      gh.define_singleton_method(:merged_prs_page) do |**kwargs|
        original_page.call(**kwargs)
        clock.advance(kwargs.fetch(:timeout_sec))
        raise Hive::GhError, "GitHub unavailable"
      end

      failed = reconciler(
        dir, gh, monotonic_clock: clock,
        tick_budget_sec: 5, max_call_timeout_sec: 5,
        jitter: -> { 0.0 }
      ).tick(now: T0 + 1).fetch(0)
      retry_state = JSON.parse(File.read(progress_path(dir))).fetch("retry")

      assert_equal :blocked, failed.fetch(:status)
      assert_equal T0 + 8.5, Time.iso8601(retry_state.fetch("not_before")),
                   "the 2.5s backoff must begin after the 5s failed call"
      calls_after_failure = gh.page_calls.length

      waiting = reconciler(
        dir, gh, monotonic_clock: clock,
        tick_budget_sec: 5, max_call_timeout_sec: 5,
        jitter: -> { 0.0 }
      ).tick(now: T0 + 6).fetch(0)

      assert_equal :backoff, waiting.fetch(:status)
      assert_equal calls_after_failure, gh.page_calls.length
    end
  end

  def test_slow_failing_project_gets_only_its_slice_and_does_not_starve_next_project
    with_tmp_dir do |slow_dir|
      with_tmp_dir do |fast_dir|
        clock = FakeMonotonic.new
        identities = { slow_dir => "acme/slow", fast_dir => "acme/fast" }
        gh = MultiProjectGh.new(identities: identities, clock: clock)
        gh.slow_repository = "acme/slow"
        entries = [
          { "name" => "slow", "path" => slow_dir },
          { "name" => "fast", "path" => fast_dir }
        ]
        intake = Hive::Daemon::RefactorPatrolMergeReconciler.new(
          registry: -> { entries }, config_loader: ->(*) { enabled_cfg },
          gh: gh, github_gateway: gh, poll_interval_sec: 0,
          tick_budget_sec: 10, max_call_timeout_sec: 10,
          monotonic_clock: clock, jitter: -> { 0.0 }
        )

        results = intake.tick(now: T0)

        assert_equal [ :blocked, :seeded ], results.map { |result| result.fetch(:status) }
        assert_equal [ "acme/slow", "acme/fast" ], gh.page_calls.map { |call| call.fetch(:repository) }
        assert_in_delta 5.0, gh.page_calls.first.fetch(:timeout_sec), 0.001
        assert File.file?(state_path(fast_dir)), "later project must complete inside the same tick"
      end
    end
  end

  def test_checkpoint_write_before_progress_unlink_is_harmless_on_restart
    with_tmp_dir do |dir|
      gh = FakeGh.new
      gh.pages = { nil => page([ summary(1, at: T0) ]) }
      progress = progress_path(dir)
      original_delete = File.method(:delete)
      blocked = nil

      with_replaced_singleton_method(File, :delete, lambda { |path|
        raise IOError, "simulated crash before progress unlink" if path == progress

        original_delete.call(path)
      }) do
        blocked = reconciler(dir, gh).tick(now: T0).fetch(0)
      end

      assert_equal :blocked, blocked.fetch(:status)
      assert File.file?(state_path(dir)), "checkpoint must already be durable"
      assert File.file?(progress), "pre-checkpoint-fingerprint sidecar remains after simulated crash"

      gh.pages = { nil => page([]) }
      resumed = reconciler(dir, gh).tick(now: T0 + 1).fetch(0)

      assert_equal :ok, resumed.fetch(:status)
      assert_equal 1, JSON.parse(File.read(state_path(dir))).dig("high_water", "pr_number")
      refute File.exist?(progress)
      assert_empty job_store(dir).jobs
    end
  end

  def test_manifest_hydration_receives_a_bounded_slice_of_the_tick_deadline
    with_tmp_dir do |dir|
      gh = FakeGh.new
      gh.pages = { nil => page([ summary(1, at: T0) ]) }
      reconciler(dir, gh, tick_budget_sec: 2, max_call_timeout_sec: 2).tick(now: T0)
      gh.pages = { nil => page([ summary(2, at: T0 + 1) ]) }
      gh.details = { 2 => details(2, at: T0 + 1) }

      result = reconciler(
        dir, gh, tick_budget_sec: 2, max_call_timeout_sec: 2
      ).tick(now: T0 + 2).fetch(0)

      assert_equal :ok, result.fetch(:status)
      assert_equal 1, gh.detail_calls.length
      assert_operator gh.detail_calls.fetch(0).fetch(:timeout_sec), :>, 0
      assert_operator gh.detail_calls.fetch(0).fetch(:timeout_sec), :<=, 2
    end
  end

  def test_repository_identity_and_page_share_one_project_step_deadline
    with_tmp_dir do |dir|
      clock = FakeMonotonic.new
      gh = FakeGh.new
      gh.pages = { nil => page([]) }
      original_identity = gh.method(:repository_identity)
      gh.define_singleton_method(:repository_identity) do |*args, timeout_sec:, **kwargs|
        identity = original_identity.call(*args, timeout_sec: timeout_sec, **kwargs)
        clock.advance(timeout_sec)
        identity
      end

      result = reconciler(
        dir, gh, monotonic_clock: clock,
        tick_budget_sec: 1, max_call_timeout_sec: 1
      ).tick(now: T0).fetch(0)

      assert_equal :deferred, result.fetch(:status)
      assert_in_delta 1, gh.identity_calls.fetch(0), 0.001
      assert_empty gh.page_calls,
                   "page fetch must not start after identity lookup spends the project slice"
    end
  end

  def test_immediate_identity_and_hydration_share_the_dispatcher_deadline
    with_tmp_dir do |dir|
      clock = FakeMonotonic.new
      gh = FakeGh.new
      gh.details = { 7 => details(7, at: T0) }
      original_identity = gh.method(:repository_identity)
      gh.define_singleton_method(:repository_identity) do |*args, timeout_sec:, **kwargs|
        identity = original_identity.call(*args, timeout_sec: timeout_sec, **kwargs)
        clock.advance(timeout_sec)
        identity
      end
      intake = reconciler(
        dir, gh, monotonic_clock: clock,
        tick_budget_sec: 2, max_call_timeout_sec: 2
      )

      result = intake.ingest(
        project: "demo", pr: "https://github.com/acme/demo/pull/7", now: T0
      )

      assert_equal :deferred, result
      assert_in_delta 2, gh.identity_calls.fetch(0), 0.001
      assert_empty gh.detail_calls,
                   "hydration must not start after identity lookup spends the shared deadline"
    end
  end

  def test_immediate_hydration_shares_the_catch_up_tick_deadline
    with_tmp_dir do |dir|
      clock = FakeMonotonic.new
      gh = FakeGh.new
      gh.pages = { nil => page([]) }
      original_page = gh.method(:merged_prs_page)
      gh.define_singleton_method(:merged_prs_page) do |**kwargs|
        result = original_page.call(**kwargs)
        clock.advance(kwargs.fetch(:timeout_sec))
        result
      end
      intake = reconciler(
        dir, gh, monotonic_clock: clock,
        tick_budget_sec: 2, max_call_timeout_sec: 2
      )

      assert_equal :seeded, intake.tick(now: T0).fetch(0).fetch(:status)
      gh.details = { 7 => details(7, at: T0) }

      assert_nil intake.watcher_poll_timeout(project: "demo", now: T0, maximum: 60)
      assert_equal :deferred, intake.ingest(
        project: "demo", pr: "https://github.com/acme/demo/pull/7", now: T0
      )
      assert_empty gh.detail_calls,
                   "immediate hydration must not start after catch-up spent the shared deadline"

      assert_in_delta 2, intake.watcher_poll_timeout(project: "demo", now: T0 + 1, maximum: 60)
      aggregate = intake.ingest(
        project: "demo", pr: "https://github.com/acme/demo/pull/7", now: T0 + 1
      )
      assert_equal 7, aggregate.dig("source", "number")
      assert_equal 1, gh.detail_calls.length
      assert_operator gh.detail_calls.fetch(0).fetch(:timeout_sec), :>, 0
      assert_operator gh.detail_calls.fetch(0).fetch(:timeout_sec), :<=, 2
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
      cfg["refactor_patrol"]["commands"]["test"] = "bin/test"

      reconciler(dir, gh, cfg: cfg).ingest(
        project: "demo", pr: "https://github.com/acme/demo/pull/2", now: T0
      )
      policy = job_store(dir).jobs.fetch(0).fetch("policy")

      assert_equal true, policy.fetch("auto_fix")
      assert_equal true, policy.fetch("issue_filing")
      assert_equal "codex", policy.dig("action", "auto_fix_agent")
      refute policy.dig("action", "caps").key?("max_files")
      refute policy.dig("action", "caps").key?("max_diff_lines")
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
      gh.host = "github.corp.example"
      moved_host = reconciler(dir, gh, cfg: cfg).tick(now: T0 + 90).fetch(0)
      assert_equal :blocked, moved_host.fetch(:status)
      assert_match(/repository host changed/, moved_host.fetch(:reason))
      assert_equal before, File.binread(state_path(dir))

      gh.host = "github.com"
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

  def test_tick_isolates_registry_config_failures_and_default_loader_is_constructible
    with_tmp_dir do |dir|
      entry = { "name" => "demo", "path" => dir }
      intake = Hive::Daemon::RefactorPatrolMergeReconciler.new(
        registry: -> { [ entry ] },
        config_loader: ->(_path) { raise Hive::ConfigError, "broken config" },
        gh: FakeGh.new,
        github_gateway: FakeGh.new,
        poll_interval_sec: 0
      )

      result = intake.tick(now: T0).fetch(0)

      assert_equal :blocked, result.fetch(:status)
      assert_match(/broken config/, result.fetch(:reason))
      defaulted = Hive::Daemon::RefactorPatrolMergeReconciler.new(
        registry: -> { [] }, gh: FakeGh.new, github_gateway: FakeGh.new,
        poll_interval_sec: 0
      )
      FileUtils.mkdir_p(File.join(dir, ".hive-state"))
      File.write(
        File.join(dir, ".hive-state", "config.yml"),
        enabled_cfg.merge("project_name" => "demo").to_yaml
      )
      assert_equal "demo", defaulted.instance_variable_get(:@config_loader).call(dir).fetch("project_name")
      assert_empty defaulted.tick(now: T0)
    end
  end

  def test_tick_defers_before_remote_work_when_config_loading_spends_budget
    with_tmp_dir do |dir|
      clock = FakeMonotonic.new
      gh = FakeGh.new
      gh.pages = { nil => page([]) }
      entry = { "name" => "demo", "path" => dir }
      intake = Hive::Daemon::RefactorPatrolMergeReconciler.new(
        registry: -> { [ entry ] },
        config_loader: lambda { |_path|
          clock.advance(1)
          enabled_cfg
        },
        gh: gh, github_gateway: gh, poll_interval_sec: 0,
        tick_budget_sec: 1, max_call_timeout_sec: 1,
        monotonic_clock: clock
      )

      result = intake.tick(now: T0).fetch(0)

      assert_equal :deferred, result.fetch(:status)
      assert_empty gh.page_calls
      assert_equal progress_path(dir), intake.progress_path(dir)
    end
  end

  def test_watcher_timeout_falls_back_when_enabled_project_config_fails
    with_tmp_dir do |dir|
      entry = { "name" => "demo", "path" => dir }
      intake = Hive::Daemon::RefactorPatrolMergeReconciler.new(
        registry: -> { [ entry ] },
        config_loader: ->(_path) { raise Hive::ConfigError, "broken" },
        gh: FakeGh.new, github_gateway: FakeGh.new, poll_interval_sec: 0
      )

      assert_equal 3.0, intake.watcher_poll_timeout(project: "demo", now: T0, maximum: 3)
    end
  end

  def test_backoff_and_invalid_scan_persistence_failures_are_visible_blocks
    with_tmp_dir do |dir|
      gh = FakeGh.new
      gh.define_singleton_method(:merged_prs_page) { |**| raise Hive::GhError, "offline" }
      intake = reconciler(dir, gh)
      store = intake.instance_variable_get(:@progress_store)
      store.define_singleton_method(:record_failure!) { |*| raise IOError, "disk full" }

      result = intake.tick(now: T0).fetch(0)
      assert_equal :blocked, result.fetch(:status)
      assert_match(/cannot persist GitHub backoff: disk full/, result.fetch(:reason))
    end

    with_tmp_dir do |dir|
      gh = FakeGh.new
      gh.pages = { nil => page([]) }
      intake = reconciler(dir, gh)
      intake.define_singleton_method(:scan_page_step) do |*_, **|
        raise Hive::Daemon::RefactorPatrolMergeReconciler::ScanInvalidated, "search moved"
      end
      intake.define_singleton_method(:restart_scan!) { |*| raise IOError, "disk full" }

      result = intake.tick(now: T0).fetch(0)
      assert_equal :blocked, result.fetch(:status)
      assert_match(/cannot reset invalid scan: disk full/, result.fetch(:reason))
    end
  end

  def test_invalid_injected_progress_phase_blocks_defensively
    with_tmp_dir do |dir|
      gh = FakeGh.new
      intake = reconciler(dir, gh)
      store = intake.instance_variable_get(:@progress_store)
      progress = store.build(
        registration: "demo", host: "github.com", repository: "acme/demo",
        default_branch: "main", previous: nil,
        merged_since: T0 - 3600, now: T0
      )
      progress.dig("scan")["phase"] = "unexpected"
      progress.dig("scan")["result_count"] = 0
      store.define_singleton_method(:load) { |_root| progress }
      store.define_singleton_method(:write) { |_root, value| value }

      result = intake.tick(now: T0).fetch(0)
      assert_equal :blocked, result.fetch(:status)
      assert_match(/scan phase is invalid/, result.fetch(:reason))
    end
  end

  def test_merged_pr_page_validation_rejects_incomplete_invalid_and_bad_timestamp_items
    with_tmp_dir do |dir|
      intake = reconciler(dir, FakeGh.new)
      invalid_pages = [
        { "complete" => false, "items" => [], "has_next_page" => false },
        page([ nil ]).merge("total_count" => 1),
        page([ summary(1, at: T0).merge("number" => 0) ]).merge("total_count" => 1),
        page([ summary(1, at: T0).merge("url" => nil) ]).merge("total_count" => 1),
        page([ summary(1, at: T0).merge("merge_sha" => "z" * 40) ]).merge("total_count" => 1),
        page([ summary(1, at: T0).merge("merged_at" => "not-a-time") ]).merge("total_count" => 1),
        page([ summary(1, at: T0).merge("repository" => "other/repo") ]).merge("total_count" => 1),
        page([ summary(1, at: T0).merge("url" => "https://example.com/acme/demo/pull/1") ])
          .merge("total_count" => 1),
        page([ summary(1, at: T0).merge("base_branch" => "trunk") ]).merge("total_count" => 1)
      ]

      invalid_pages.each do |invalid|
        assert_raises(Hive::Daemon::RefactorPatrolMergeReconciler::Blocked) do
          intake.send(:validate_page!, invalid, "acme/demo", "github.com", "main")
        end
      end
    end
  end

  def test_pagination_cursor_and_terminal_count_inconsistencies_fail_closed
    with_tmp_dir do |dir|
      gh = FakeGh.new
      gh.pages = {
        nil => page([ summary(1, at: T0) ], next_cursor: ""),
        "page-2" => page([ summary(2, at: T0) ], next_cursor: "page-2")
      }
      omitted = reconciler(dir, gh).tick(now: T0).fetch(0)
      assert_equal :blocked, omitted.fetch(:status)
      assert_match(/omitted next cursor/, omitted.fetch(:reason))

      FileUtils.rm_rf(File.join(dir, ".hive-state"))
      gh.pages[nil] = page([ summary(1, at: T0) ], next_cursor: "page-2")
      repeated_intake = reconciler(dir, gh)
      repeated = repeated_intake.tick(now: T0).fetch(0)
      assert_equal :blocked, repeated.fetch(:status)
      assert_match(/cursor repeated/, repeated.fetch(:reason))
    end


    with_tmp_dir do |dir|
      gh = FakeGh.new
      intake = reconciler(dir, gh)
      store = intake.instance_variable_get(:@progress_store)
      progress = store.build(
        registration: "demo", host: "github.com", repository: "acme/demo",
        default_branch: "main", previous: nil,
        merged_since: T0 - 3600, now: T0
      )
      progress.dig("scan").merge!(
        "cursor" => "page-2", "seen_cursors" => [ "page-2" ], "result_count" => 0
      )
      error = assert_raises(Hive::Daemon::RefactorPatrolMergeReconciler::GithubFailure) do
        intake.send(
          :scan_page_step, { "name" => "demo", "path" => dir }, enabled_cfg,
          nil, progress, now: T0, timeout_sec: 1
        )
      end
      assert_match(/cursor repeated/, error.message)

      FileUtils.mkdir_p(File.dirname(store.path(dir)))
      File.write(store.path(dir), JSON.generate(progress))

      result = intake.tick(now: T0).fetch(0)
      assert_equal :blocked, result.fetch(:status)
      assert_match(/current cursor was already consumed/, result.fetch(:reason))
      assert_empty gh.page_calls
      refute_empty Dir.glob(
        File.join(
          dir, ".hive-state", "refactor_patrol", "v2", "quarantine",
          "reconciler-progress", "*.json"
        )
      )
    end

    with_tmp_dir do |dir|
      gh = FakeGh.new
      gh.pages = {
        nil => page([ summary(1, at: T0) ]).merge("total_count" => 2)
      }
      intake = reconciler(dir, gh)
      store = intake.instance_variable_get(:@progress_store)
      progress = store.build(
        registration: "demo", host: "github.com", repository: "acme/demo",
        default_branch: "main", previous: nil,
        merged_since: T0 - 3600, now: T0
      )
      entry = { "name" => "demo", "path" => dir }

      assert_raises(Hive::Daemon::RefactorPatrolMergeReconciler::ScanInvalidated) do
        intake.send(
          :scan_page_step, entry, enabled_cfg, nil, progress,
          now: T0, timeout_sec: 1
        )
      end
    end
  end

  def test_progress_cross_field_validation_quarantines_unsafe_resumes
    with_tmp_dir do |dir|
      intake = reconciler(dir, FakeGh.new)
      store = intake.instance_variable_get(:@progress_store)
      base = store.build(
        registration: "demo", host: "github.com", repository: "acme/demo",
        default_branch: "main", previous: nil,
        merged_since: T0 - 3600, now: T0
      )
      variants = [
        mutate_progress(base) { |scan| scan["merged_until"] = (T0 + 1).iso8601 },
        mutate_progress(base) do |scan|
          scan["cursor"] = "page-2"
          scan["result_count"] = nil
        end,
        mutate_progress(base) { |scan| scan["ingest_index"] = 1 },
        mutate_progress(base) do |scan|
          scan["items"] = [ summary(1, at: T0), summary(1, at: T0) ]
          scan["result_count"] = 2
        end,
        mutate_progress(base) do |scan|
          scan["phase"] = "ingest"
          scan["cursor"] = "page-2"
          scan["result_count"] = 0
        end,
        mutate_progress(base) do |scan|
          scan["phase"] = "ingest"
          scan["result_count"] = 1
        end,
        mutate_progress(base) do |scan|
          scan["phase"] = "ingest"
          scan["result_count"] = 0
          scan["ingest_index"] = 1
        end
      ]

      variants.each do |progress|
        assert_raises(Hive::Daemon::RefactorPatrolMergeReconciler::Blocked) do
          intake.send(:validate_progress_against_checkpoint!, progress, nil, dir)
        end
      end
    end
  end

  def test_deduplication_and_manifest_summary_conflicts_fail_closed
    with_tmp_dir do |dir|
      intake = reconciler(dir, FakeGh.new)
      first = summary(7, at: T0)
      divergent = first.merge("url" => "https://github.com/acme/demo/pull/changed")

      error = assert_raises(Hive::Daemon::RefactorPatrolMergeReconciler::Blocked) do
        intake.send(:dedupe_items, [ first, divergent ])
      end
      assert_match(/divergent payloads/, error.message)

      manifest = { "source" => first.merge("number" => 8) }
      error = assert_raises(Hive::Daemon::RefactorPatrolMergeReconciler::Blocked) do
        intake.send(:assert_manifest_matches!, manifest, first)
      end
      assert_match(/conflicts with immutable manifest/, error.message)
    end
  end

  def test_invalid_overlap_and_occurrence_checkpoint_shapes_are_quarantined
    with_tmp_dir do |dir|
      intake = reconciler(dir, FakeGh.new)
      path = state_path(dir)
      FileUtils.mkdir_p(File.dirname(path))
      base = intake.send(
        :build_state,
        registration: "demo", host: "github.com", repository: "acme/demo",
        default_branch: "main", high_water: nil, overlap_occurrences: [],
        seeded_at: T0, updated_at: T0
      )
      invalid_states = [
        base.merge("overlap_occurrences" => {}),
        base.merge("updated_at" => 123),
        base.merge("high_water" => {
          "merged_at" => 123, "pr_number" => 1, "merge_sha" => "a" * 40
        }),
        base.merge("overlap_occurrences" => [
          { "merged_at" => T0.iso8601, "pr_number" => 0, "merge_sha" => "a" * 40 }
        ]),
        base.merge("overlap_occurrences" => [
          { "merged_at" => 123, "pr_number" => 1, "merge_sha" => "a" * 40 }
        ]),
        base.merge("overlap_occurrences" => [
          { "merged_at" => T0.iso8601, "pr_number" => 1, "merge_sha" => 123 }
        ])
      ]

      invalid_states.each do |state|
        File.write(path, JSON.generate(state))
        assert_raises(Hive::Daemon::RefactorPatrolMergeReconciler::Blocked) do
          intake.send(:load_state, dir)
        end
      end
      refute_empty quarantine_paths(dir)
    end
  end

  def test_registered_identity_errors_are_converted_to_a_stable_block
    with_tmp_dir do |dir|
      gh = FakeGh.new
      gh.define_singleton_method(:repository_identity) { |*| raise Hive::GhError, "no remote" }
      intake = reconciler(dir, gh)

      error = assert_raises(Hive::Daemon::RefactorPatrolMergeReconciler::Blocked) do
        intake.send(:registered_identity, dir, enabled_cfg)
      end

      assert_match(/identity is unavailable/, error.message)
    end
  end

  def test_budget_configuration_requires_finite_positive_numbers
    gh = FakeGh.new
    [ 0, -1, Float::NAN ].each do |value|
      assert_raises(ArgumentError) { reconciler("/tmp/demo", gh, tick_budget_sec: value) }
    end
    [ "bad", Object.new ].each do |value|
      assert_raises(ArgumentError) { reconciler("/tmp/demo", gh, max_call_timeout_sec: value) }
    end
  end

  private

  def reconciler(dir, gh, cfg: enabled_cfg, name: "demo", **options)
    entry = { "name" => name, "path" => dir, "hive_state_path" => File.join(dir, ".hive-state") }
    Hive::Daemon::RefactorPatrolMergeReconciler.new(
      registry: -> { [ entry ] },
      config_loader: ->(_path) { cfg },
      gh: gh,
      overlap_sec: 3600,
      page_size: 2,
      poll_interval_sec: 0,
      **options
    )
  end

  def enabled_cfg
    Hive::Config.deep_merge(
      Hive::Config.deep_dup(Hive::Config::DEFAULTS),
      {
        "default_branch" => "main",
        "execute" => {
          "agent" => "codex", "model" => "gpt-5.6-sol", "effort" => "high"
        },
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

  def mutate_progress(progress)
    copy = Marshal.load(Marshal.dump(progress))
    yield copy.fetch("scan")
    copy
  end

  def state_path(dir)
    File.join(dir, ".hive-state", "refactor_patrol", "v2", "reconciler.json")
  end

  def progress_path(dir)
    File.join(dir, ".hive-state", "refactor_patrol", "v2", "reconciler-progress.json")
  end

  def job_store(dir)
    Hive::RefactorPatrol::JobStore.new(dir)
  end

  def quarantine_paths(dir)
    Dir.glob(File.join(dir, ".hive-state", "refactor_patrol", "v2", "quarantine", "reconciler", "*.json"))
  end
end
