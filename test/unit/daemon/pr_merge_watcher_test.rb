require "test_helper"
require "tmpdir"
require "hive/daemon/pr_merge_watcher"

# Pin PrMergeWatcher's polling cadence + state classification +
# failure-backoff. Uses test/fixtures/fake-gh.rb for deterministic gh
# pr view responses (controlled via HIVE_FAKE_GH_STATE / EXIT envs).
class HiveDaemonPrMergeWatcherTest < Minitest::Test
  include HiveTestHelper

  FAKE_GH = File.expand_path("../../fixtures/fake-gh.rb", __dir__)

  class FakeMergeIntake
    attr_accessor :error, :outcomes, :poll_timeout
    attr_reader :calls, :budget_calls

    def initialize(error: nil)
      @error = error
      @calls = []
      @outcomes = []
      @poll_timeout = :default
      @budget_calls = []
    end

    def watcher_poll_timeout(**kwargs)
      @budget_calls << kwargs
      poll_timeout == :default ? kwargs.fetch(:maximum) : poll_timeout
    end

    def ingest(**kwargs)
      @calls << kwargs
      raise error if error

      outcomes.empty? ? { "job_id" => "durable" } : outcomes.shift
    end
  end

  def make(poll_interval_sec: 60, merge_intake: nil, poll_timeout_sec: 60)
    Hive::Daemon::PrMergeWatcher.new(
      poll_interval_sec: poll_interval_sec,
      gh_bin: FAKE_GH,
      merge_intake: merge_intake,
      poll_timeout_sec: poll_timeout_sec
    )
  end

  def with_pr_md(url:, &block)
    with_tmp_dir do |dir|
      pr_md = File.join(dir, "pr.md")
      File.write(pr_md, <<~MD)
        ---
        pr_url: #{url}
        pr_number: 42
        ---

        ## body

        body text here
      MD
      block.call(dir)
    end
  end

  # ── enqueue ───────────────────────────────────────────────────────────

  def test_enqueue_reads_pr_url_from_pr_md
    with_pr_md(url: "https://github.com/u/r/pull/42") do |folder|
      watcher = make
      watcher.enqueue(project: "p1", slug: "s1", task_folder: folder)
      assert_equal 1, watcher.pending_count
      assert watcher.watching?(project: "p1", slug: "s1")
    end
  end

  def test_enqueue_is_idempotent
    with_pr_md(url: "https://github.com/u/r/pull/42") do |folder|
      watcher = make
      watcher.enqueue(project: "p1", slug: "s1", task_folder: folder)
      watcher.enqueue(project: "p1", slug: "s1", task_folder: folder)
      assert_equal 1, watcher.pending_count
    end
  end

  def test_enqueue_skips_when_pr_md_missing
    with_tmp_dir do |dir|
      watcher = make
      watcher.enqueue(project: "p1", slug: "s1", task_folder: dir)
      assert_equal 0, watcher.pending_count
    end
  end

  def test_enqueue_skips_when_pr_url_unparseable
    with_tmp_dir do |dir|
      File.write(File.join(dir, "pr.md"), "no frontmatter at all\n")
      watcher = make
      watcher.enqueue(project: "p1", slug: "s1", task_folder: dir)
      assert_equal 0, watcher.pending_count
    end
  end

  # ── tick: state classification ────────────────────────────────────────

  def test_tick_with_open_state_does_not_archive
    with_pr_md(url: "x") do |folder|
      watcher = make(poll_interval_sec: 0)
      watcher.enqueue(project: "p1", slug: "s1", task_folder: folder)

      with_env("HIVE_FAKE_GH_STATE" => "OPEN") do
        result = watcher.tick(now: Time.now)
        assert_equal [], result
        assert watcher.watching?(project: "p1", slug: "s1")
      end
    end
  end

  def test_tick_with_merged_state_returns_archive_dispatch
    with_pr_md(url: "x") do |folder|
      watcher = make(poll_interval_sec: 0)
      watcher.enqueue(project: "p1", slug: "s1", task_folder: folder)

      with_env("HIVE_FAKE_GH_STATE" => "MERGED") do
        result = watcher.tick(now: Time.now)
        assert_equal 1, result.size
        archive = result.first
        assert_equal "p1", archive[:project]
        assert_equal "s1", archive[:slug]
        assert_match(/^hive archive s1 --from 8-finalize --project p1/, archive[:command])
        # Entry removed after dispatch
        refute watcher.watching?(project: "p1", slug: "s1")
      end
    end
  end

  def test_merged_archive_waits_for_shared_durable_intake
    with_pr_md(url: "https://github.com/u/r/pull/42") do |folder|
      intake = FakeMergeIntake.new
      watcher = make(poll_interval_sec: 0, merge_intake: intake)
      watcher.enqueue(project: "p1", slug: "s1", task_folder: folder)
      now = Time.utc(2026, 7, 10, 12)

      with_env("HIVE_FAKE_GH_STATE" => "MERGED") do
        archives = watcher.tick(now: now)

        assert_equal 1, archives.size
        assert_equal [ { project: "p1", pr: "https://github.com/u/r/pull/42", now: now } ], intake.calls
      end
    end
  end

  def test_intake_failure_holds_archive_and_retries_same_watcher_entry
    with_pr_md(url: "https://github.com/u/r/pull/42") do |folder|
      intake = FakeMergeIntake.new(error: Hive::GhError.new("manifest unavailable"))
      watcher = make(poll_interval_sec: 0, merge_intake: intake)
      watcher.enqueue(project: "p1", slug: "s1", task_folder: folder)
      now = Time.utc(2026, 7, 10, 12)

      with_env("HIVE_FAKE_GH_STATE" => "MERGED") do
        assert_empty watcher.tick(now: now)
        assert watcher.watching?(project: "p1", slug: "s1")

        intake.error = nil
        archives = watcher.tick(now: now + Hive::Daemon::PrMergeWatcher::GH_BACKOFF_SCHEDULE.first + 1)
        assert_equal 1, archives.size
        assert_equal 2, intake.calls.size
      end
    end
  end

  def test_deferred_intake_stops_the_batch_without_burning_failure_budget
    with_pr_md(url: "https://github.com/u/r/pull/41") do |first_folder|
      with_pr_md(url: "https://github.com/u/r/pull/42") do |second_folder|
        intake = FakeMergeIntake.new
        intake.outcomes = [ :deferred, { "job_id" => "durable" } ]
        watcher = make(poll_interval_sec: 0, merge_intake: intake)
        watcher.enqueue(project: "p1", slug: "s1", task_folder: first_folder)
        watcher.enqueue(project: "p1", slug: "s2", task_folder: second_folder)
        now = Time.utc(2026, 7, 10, 12)

        with_env("HIVE_FAKE_GH_STATE" => "MERGED") do
          assert_empty watcher.tick(now: now)
          assert_equal 1, intake.calls.length,
                       "a spent shared deadline must not start later immediate hydrations"
          assert watcher.watching?(project: "p1", slug: "s1")
          assert watcher.watching?(project: "p1", slug: "s2")
          deferred = watcher.instance_variable_get(:@pending).fetch([ "p1", "s1" ])
          assert_equal 0, deferred.fetch(:failure_count)
          assert_nil deferred.fetch(:next_eligible_at)

          archives = watcher.tick(now: now + 1)
          assert_equal 2, archives.length
          assert_equal "s1", archives.fetch(0).fetch(:slug)
          assert_equal "s2", archives.fetch(1).fetch(:slug)
          assert_equal 3, intake.calls.length
          refute watcher.watching?(project: "p1", slug: "s2")
        end
      end
    end
  end

  def test_spent_shared_budget_defers_before_polling_without_burning_failure_budget
    with_pr_md(url: "https://github.com/u/r/pull/42") do |folder|
      intake = FakeMergeIntake.new
      intake.poll_timeout = nil
      watcher = make(poll_interval_sec: 0, merge_intake: intake)
      watcher.enqueue(project: "p1", slug: "s1", task_folder: folder)
      now = Time.utc(2026, 7, 10, 12)

      with_env("HIVE_FAKE_GH_STATE" => "MERGED") do
        assert_empty watcher.tick(now: now)
      end

      assert_empty intake.calls
      assert_equal [ { project: "p1", now: now, maximum: 60.0 } ], intake.budget_calls
      pending = watcher.instance_variable_get(:@pending).fetch([ "p1", "s1" ])
      assert_equal 0, pending.fetch(:failure_count)
      assert_nil pending.fetch(:last_polled_at)
    end
  end

  def test_poll_timeout_validation_and_budget_coordination_fallback
    [ 0, -1, Float::NAN ].each do |value|
      assert_raises(ArgumentError) { make(poll_timeout_sec: value) }
    end

    intake = FakeMergeIntake.new
    intake.poll_timeout = Object.new
    watcher = make(merge_intake: intake, poll_timeout_sec: 7)
    now = Time.utc(2026, 7, 10, 12)

    assert_equal 7.0, watcher.send(:poll_timeout_for, project: "p1", now: now)
    assert_equal [ { project: "p1", now: now, maximum: 7.0 } ], intake.budget_calls
  end

  def test_repeated_intake_failures_preserve_the_failure_counter
    with_pr_md(url: "https://github.com/u/r/pull/42") do |folder|
      intake = FakeMergeIntake.new(error: Hive::GhError.new("manifest unavailable"))
      watcher = make(poll_interval_sec: 0, merge_intake: intake)
      watcher.enqueue(project: "p1", slug: "s1", task_folder: folder)
      now = Time.utc(2026, 7, 10, 12)

      with_env("HIVE_FAKE_GH_STATE" => "MERGED") do
        assert_empty watcher.tick(now: now)
        assert_empty watcher.tick(now: now + 61)

        pending = watcher.instance_variable_get(:@pending).fetch([ "p1", "s1" ])
        assert_equal 2, pending.fetch(:failure_count)
        assert_equal now + 61 + Hive::Daemon::PrMergeWatcher::GH_BACKOFF_SCHEDULE.fetch(1),
                     pending.fetch(:next_eligible_at)
      end
    end
  end

  def test_tick_with_merged_state_carries_recoverable_error_reason
    with_pr_md(url: "x") do |folder|
      watcher = make(poll_interval_sec: 0)
      watcher.enqueue(project: "p1", slug: "s1", task_folder: folder,
                      error_reason: "git_status_failed")

      with_env("HIVE_FAKE_GH_STATE" => "MERGED") do
        result = watcher.tick(now: Time.now)
        assert_equal 1, result.size
        archive = result.first
        assert_equal "git_status_failed", archive[:error_reason]
        assert_match(/--recover-merged-error-reason git_status_failed\z/, archive[:command])
      end
    end
  end

  def test_enqueue_ignores_unknown_error_reason
    with_pr_md(url: "x") do |folder|
      watcher = make(poll_interval_sec: 0)
      watcher.enqueue(project: "p1", slug: "s1", task_folder: folder,
                      error_reason: "ensure_clean_on_exit_failed")

      with_env("HIVE_FAKE_GH_STATE" => "MERGED") do
        archive = watcher.tick(now: Time.now).first
        refute_match(/recover-merged-error-reason/, archive[:command])
        assert_nil archive[:error_reason]
      end
    end
  end

  def test_tick_with_closed_state_drops_entry
    with_pr_md(url: "x") do |folder|
      watcher = make(poll_interval_sec: 0)
      watcher.enqueue(project: "p1", slug: "s1", task_folder: folder)

      with_env("HIVE_FAKE_GH_STATE" => "CLOSED") do
        result = watcher.tick(now: Time.now)
        assert_equal [], result, "CLOSED → no archive dispatch"
        refute watcher.watching?(project: "p1", slug: "s1"),
               "CLOSED PR drops the watcher entry; operator handles next"
      end
    end
  end

  # ── tick: poll cadence ───────────────────────────────────────────────

  def test_tick_respects_poll_interval
    with_pr_md(url: "x") do |folder|
      watcher = make(poll_interval_sec: 60)
      watcher.enqueue(project: "p1", slug: "s1", task_folder: folder)

      with_env("HIVE_FAKE_GH_STATE" => "OPEN") do
        now = Time.now
        watcher.tick(now: now)
        # Second call too soon — should NOT poll
        ENV["HIVE_FAKE_GH_STATE"] = "MERGED"
        result = watcher.tick(now: now + 30)
        assert_equal [], result, "second tick within poll_interval_sec must NOT re-poll"

        # After interval elapses, fresh poll picks up MERGED
        result = watcher.tick(now: now + 65)
        assert_equal 1, result.size
      end
    end
  end

  # ── tick: failure backoff and drop after max ──────────────────────────

  def test_tick_with_gh_error_increments_failure_count
    with_pr_md(url: "x") do |folder|
      watcher = make(poll_interval_sec: 0)
      watcher.enqueue(project: "p1", slug: "s1", task_folder: folder)

      with_env("HIVE_FAKE_GH_EXIT" => "1", "HIVE_FAKE_GH_STDERR" => "auth required") do
        result = watcher.tick(now: Time.now)
        assert_equal [], result
        assert watcher.watching?(project: "p1", slug: "s1"),
               "single failure must not drop entry"
      end
    end
  end

  def test_tick_drops_after_max_consecutive_failures
    with_pr_md(url: "x") do |folder|
      watcher = make(poll_interval_sec: 0)
      watcher.enqueue(project: "p1", slug: "s1", task_folder: folder)

      with_env("HIVE_FAKE_GH_EXIT" => "1", "HIVE_FAKE_GH_STDERR" => "boom") do
        # Advance well past every backoff window between attempts so each
        # tick actually polls (rather than being gated by next_eligible_at).
        now = Time.now
        last_tick_dropped = nil
        Hive::Daemon::PrMergeWatcher::GH_MAX_FAILURES.times do |i|
          watcher.tick(now: now + i * 10_000)
          last_tick_dropped = watcher.last_tick_dropped
        end
        refute watcher.watching?(project: "p1", slug: "s1"),
               "after GH_MAX_FAILURES consecutive errors, watcher must drop the entry"

        # ce-code-review P1 #9: the exhausted-failure drop must surface
        # in last_tick_dropped so the dispatcher can emit a
        # :merge_watcher_dropped logger event. Without this signal, a
        # task whose merged PR could not be confirmed silently sat at
        # ready_to_archive forever.
        assert_equal 1, last_tick_dropped.size,
                     "drop must be recorded in last_tick_dropped on the final tick"
        drop = last_tick_dropped.first
        assert_equal "p1", drop[:project]
        assert_equal "s1", drop[:slug]
        assert_equal "x", drop[:pr_url]
        assert_equal Hive::Daemon::PrMergeWatcher::GH_MAX_FAILURES, drop[:failure_count]
        assert_match(/boom/, drop[:last_error].to_s,
                     "last_error must carry the gh stderr/exit detail")

        # No queued entries left to drop, so a subsequent tick must
        # reset the buffer or downstream emitters would re-log the same
        # drop on every tick.
        watcher.tick(now: now + 1_000_000)
        assert_empty watcher.last_tick_dropped,
                     "last_tick_dropped must be reset to empty when no new drops occur"
      end
    end
  end

  def test_tick_honors_backoff_after_failure
    with_pr_md(url: "x") do |folder|
      watcher = make(poll_interval_sec: 0)
      watcher.enqueue(project: "p1", slug: "s1", task_folder: folder)

      with_env("HIVE_FAKE_GH_EXIT" => "1", "HIVE_FAKE_GH_STDERR" => "boom", "HIVE_FAKE_GH_STATE" => nil) do
        now = Time.now
        watcher.tick(now: now)
        # Inside the first backoff window (60s), tick should NOT re-poll
        # even though gh would now succeed.
        ENV["HIVE_FAKE_GH_EXIT"] = "0"
        ENV["HIVE_FAKE_GH_STDERR"] = nil
        ENV["HIVE_FAKE_GH_STATE"] = "MERGED"
        result = watcher.tick(now: now + 30)
        assert_equal [], result, "must NOT re-poll within backoff window"
        assert watcher.watching?(project: "p1", slug: "s1")

        # Past 60s, the watcher polls again and sees MERGED.
        result = watcher.tick(now: now + 90)
        assert_equal 1, result.size
        assert_equal "s1", result.first[:slug]
      end
    end
  end

  def test_successful_poll_clears_backoff
    with_pr_md(url: "x") do |folder|
      watcher = make(poll_interval_sec: 0)
      watcher.enqueue(project: "p1", slug: "s1", task_folder: folder)

      with_env("HIVE_FAKE_GH_EXIT" => nil, "HIVE_FAKE_GH_STDERR" => nil, "HIVE_FAKE_GH_STATE" => nil) do
        now = Time.now
        ENV["HIVE_FAKE_GH_EXIT"] = "1"
        ENV["HIVE_FAKE_GH_STDERR"] = "transient"
        watcher.tick(now: now) # failure → backoff

        # Force a successful OPEN poll well past backoff
        ENV["HIVE_FAKE_GH_EXIT"] = nil
        ENV["HIVE_FAKE_GH_STDERR"] = nil
        ENV["HIVE_FAKE_GH_STATE"] = "OPEN"
        watcher.tick(now: now + 90) # success → backoff cleared

        # A subsequent failure must restart from the FIRST backoff slot
        # (60s), not jump straight to 300s — i.e., success reset the
        # failure counter.
        ENV["HIVE_FAKE_GH_STATE"] = nil
        ENV["HIVE_FAKE_GH_EXIT"] = "1"
        ENV["HIVE_FAKE_GH_STDERR"] = "transient again"
        watcher.tick(now: now + 100)
        # Within the first backoff window from this new failure
        ENV["HIVE_FAKE_GH_EXIT"] = "0"
        ENV["HIVE_FAKE_GH_STDERR"] = nil
        ENV["HIVE_FAKE_GH_STATE"] = "MERGED"
        result = watcher.tick(now: now + 130) # 30s after the new failure
        assert_equal [], result, "after success-reset, next failure starts at the first backoff slot"
      end
    end
  end

  def test_state_for_returns_last_polled_state
    with_pr_md(url: "x") do |folder|
      watcher = make(poll_interval_sec: 0)
      watcher.enqueue(project: "p1", slug: "s1", task_folder: folder)

      with_env("HIVE_FAKE_GH_STATE" => "OPEN") do
        watcher.tick(now: Time.now)
        assert_equal "OPEN", watcher.state_for(project: "p1", slug: "s1")
      end
    end
  end

  def test_tick_with_malformed_gh_json_keeps_entry_for_retry
    with_tmp_dir do |dir|
      bad_gh = File.join(dir, "bad-gh")
      File.write(bad_gh, <<~RUBY_SCRIPT)
        #!/usr/bin/env ruby
        $stdout.write("not-json")
      RUBY_SCRIPT
      FileUtils.chmod(0o755, bad_gh)

      with_pr_md(url: "x") do |folder|
        watcher = Hive::Daemon::PrMergeWatcher.new(poll_interval_sec: 0, gh_bin: bad_gh)
        watcher.enqueue(project: "p1", slug: "s1", task_folder: folder)

        result = watcher.tick(now: Time.now)

        assert_equal [], result
        assert watcher.watching?(project: "p1", slug: "s1"),
               "malformed gh JSON is a retryable poll failure"
      end
    end
  end

  def test_tick_with_missing_gh_binary_keeps_entry_for_retry
    with_tmp_dir do |dir|
      missing_gh = File.join(dir, "missing-gh")
      with_pr_md(url: "x") do |folder|
        watcher = Hive::Daemon::PrMergeWatcher.new(poll_interval_sec: 0, gh_bin: missing_gh)
        watcher.enqueue(project: "p1", slug: "s1", task_folder: folder)

        result = watcher.tick(now: Time.now)

        assert_equal [], result
        assert watcher.watching?(project: "p1", slug: "s1"),
               "unexpected gh execution errors are retryable poll failures"
      end
    end
  end

  def test_hanging_gh_poll_is_terminated_within_the_explicit_timeout
    with_tmp_dir do |dir|
      hanging_gh = File.join(dir, "hanging-gh")
      File.write(hanging_gh, "#!/bin/sh\nexec sleep 5\n")
      FileUtils.chmod(0o755, hanging_gh)

      with_pr_md(url: "x") do |folder|
        watcher = Hive::Daemon::PrMergeWatcher.new(
          poll_interval_sec: 0, gh_bin: hanging_gh, poll_timeout_sec: 0.05
        )
        watcher.enqueue(project: "p1", slug: "s1", task_folder: folder)
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)

        assert_empty watcher.tick(now: Time.now)

        elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
        assert_operator elapsed, :<, 2
        assert watcher.watching?(project: "p1", slug: "s1")
        pending = watcher.instance_variable_get(:@pending).fetch([ "p1", "s1" ])
        assert_equal 1, pending.fetch(:failure_count)
      end
    end
  end

  # ── manual drop ───────────────────────────────────────────────────────

  def test_drop_removes_entry
    with_pr_md(url: "x") do |folder|
      watcher = make
      watcher.enqueue(project: "p1", slug: "s1", task_folder: folder)
      assert watcher.watching?(project: "p1", slug: "s1")
      watcher.drop(project: "p1", slug: "s1")
      refute watcher.watching?(project: "p1", slug: "s1")
    end
  end
end
