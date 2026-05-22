require "test_helper"
require "tmpdir"
require "hive/daemon/pr_merge_watcher"

# Pin PrMergeWatcher's polling cadence + state classification +
# failure-backoff. Uses test/fixtures/fake-gh.rb for deterministic gh
# pr view responses (controlled via HIVE_FAKE_GH_STATE / EXIT envs).
class HiveDaemonPrMergeWatcherTest < Minitest::Test
  include HiveTestHelper

  FAKE_GH = File.expand_path("../../fixtures/fake-gh.rb", __dir__)

  def make(poll_interval_sec: 60)
    Hive::Daemon::PrMergeWatcher.new(
      poll_interval_sec: poll_interval_sec,
      gh_bin: FAKE_GH
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

      ENV["HIVE_FAKE_GH_STATE"] = "OPEN"
      result = watcher.tick(now: Time.now)
      assert_equal [], result
      assert watcher.watching?(project: "p1", slug: "s1")
    end
  ensure
    ENV.delete("HIVE_FAKE_GH_STATE")
  end

  def test_tick_with_merged_state_returns_archive_dispatch
    with_pr_md(url: "x") do |folder|
      watcher = make(poll_interval_sec: 0)
      watcher.enqueue(project: "p1", slug: "s1", task_folder: folder)

      ENV["HIVE_FAKE_GH_STATE"] = "MERGED"
      result = watcher.tick(now: Time.now)
      assert_equal 1, result.size
      archive = result.first
      assert_equal "p1", archive[:project]
      assert_equal "s1", archive[:slug]
      assert_match(/^hive archive s1 --from 8-finalize --project p1/, archive[:command])
      # Entry removed after dispatch
      refute watcher.watching?(project: "p1", slug: "s1")
    end
  ensure
    ENV.delete("HIVE_FAKE_GH_STATE")
  end

  def test_tick_with_closed_state_drops_entry
    with_pr_md(url: "x") do |folder|
      watcher = make(poll_interval_sec: 0)
      watcher.enqueue(project: "p1", slug: "s1", task_folder: folder)

      ENV["HIVE_FAKE_GH_STATE"] = "CLOSED"
      result = watcher.tick(now: Time.now)
      assert_equal [], result, "CLOSED → no archive dispatch"
      refute watcher.watching?(project: "p1", slug: "s1"),
             "CLOSED PR drops the watcher entry; operator handles next"
    end
  ensure
    ENV.delete("HIVE_FAKE_GH_STATE")
  end

  # ── tick: poll cadence ───────────────────────────────────────────────

  def test_tick_respects_poll_interval
    with_pr_md(url: "x") do |folder|
      watcher = make(poll_interval_sec: 60)
      watcher.enqueue(project: "p1", slug: "s1", task_folder: folder)

      ENV["HIVE_FAKE_GH_STATE"] = "OPEN"
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
  ensure
    ENV.delete("HIVE_FAKE_GH_STATE")
  end

  # ── tick: failure backoff and drop after max ──────────────────────────

  def test_tick_with_gh_error_increments_failure_count
    with_pr_md(url: "x") do |folder|
      watcher = make(poll_interval_sec: 0)
      watcher.enqueue(project: "p1", slug: "s1", task_folder: folder)

      ENV["HIVE_FAKE_GH_EXIT"] = "1"
      ENV["HIVE_FAKE_GH_STDERR"] = "auth required"
      result = watcher.tick(now: Time.now)
      assert_equal [], result
      assert watcher.watching?(project: "p1", slug: "s1"),
             "single failure must not drop entry"
    end
  ensure
    ENV.delete("HIVE_FAKE_GH_EXIT")
    ENV.delete("HIVE_FAKE_GH_STDERR")
  end

  def test_tick_drops_after_max_consecutive_failures
    with_pr_md(url: "x") do |folder|
      watcher = make(poll_interval_sec: 0)
      watcher.enqueue(project: "p1", slug: "s1", task_folder: folder)

      ENV["HIVE_FAKE_GH_EXIT"] = "1"
      ENV["HIVE_FAKE_GH_STDERR"] = "boom"
      # Advance well past every backoff window between attempts so each
      # tick actually polls (rather than being gated by next_eligible_at).
      now = Time.now
      Hive::Daemon::PrMergeWatcher::GH_MAX_FAILURES.times do |i|
        watcher.tick(now: now + i * 10_000)
      end
      refute watcher.watching?(project: "p1", slug: "s1"),
             "after GH_MAX_FAILURES consecutive errors, watcher must drop the entry"
    end
  ensure
    ENV.delete("HIVE_FAKE_GH_EXIT")
    ENV.delete("HIVE_FAKE_GH_STDERR")
  end

  # PR-40 follow-up review C3: GH_BACKOFF_SCHEDULE must actually delay
  # subsequent polls after a failure. Without the gate, the watcher
  # hammered `gh` at the regular poll cadence under auth/rate failure.
  def test_tick_honors_backoff_after_failure
    with_pr_md(url: "x") do |folder|
      watcher = make(poll_interval_sec: 0)
      watcher.enqueue(project: "p1", slug: "s1", task_folder: folder)

      ENV["HIVE_FAKE_GH_EXIT"] = "1"
      ENV["HIVE_FAKE_GH_STDERR"] = "boom"
      now = Time.now
      watcher.tick(now: now)
      # Inside the first backoff window (60s), tick should NOT re-poll
      # even though gh would now succeed.
      ENV["HIVE_FAKE_GH_EXIT"] = "0"
      ENV["HIVE_FAKE_GH_STATE"] = "MERGED"
      result = watcher.tick(now: now + 30)
      assert_equal [], result, "must NOT re-poll within backoff window"
      assert watcher.watching?(project: "p1", slug: "s1")

      # Past 60s, the watcher polls again and sees MERGED.
      result = watcher.tick(now: now + 90)
      assert_equal 1, result.size
      assert_equal "s1", result.first[:slug]
    end
  ensure
    ENV.delete("HIVE_FAKE_GH_EXIT")
    ENV.delete("HIVE_FAKE_GH_STDERR")
    ENV.delete("HIVE_FAKE_GH_STATE")
  end

  def test_successful_poll_clears_backoff
    with_pr_md(url: "x") do |folder|
      watcher = make(poll_interval_sec: 0)
      watcher.enqueue(project: "p1", slug: "s1", task_folder: folder)

      now = Time.now
      ENV["HIVE_FAKE_GH_EXIT"] = "1"
      ENV["HIVE_FAKE_GH_STDERR"] = "transient"
      watcher.tick(now: now) # failure → backoff

      # Force a successful OPEN poll well past backoff
      ENV.delete("HIVE_FAKE_GH_EXIT")
      ENV.delete("HIVE_FAKE_GH_STDERR")
      ENV["HIVE_FAKE_GH_STATE"] = "OPEN"
      watcher.tick(now: now + 90) # success → backoff cleared

      # A subsequent failure must restart from the FIRST backoff slot
      # (60s), not jump straight to 300s — i.e., success reset the
      # failure counter.
      ENV.delete("HIVE_FAKE_GH_STATE")
      ENV["HIVE_FAKE_GH_EXIT"] = "1"
      ENV["HIVE_FAKE_GH_STDERR"] = "transient again"
      watcher.tick(now: now + 100)
      # Within the first backoff window from this new failure
      ENV["HIVE_FAKE_GH_EXIT"] = "0"
      ENV["HIVE_FAKE_GH_STATE"] = "MERGED"
      result = watcher.tick(now: now + 130) # 30s after the new failure
      assert_equal [], result, "after success-reset, next failure starts at the first backoff slot"
    end
  ensure
    ENV.delete("HIVE_FAKE_GH_EXIT")
    ENV.delete("HIVE_FAKE_GH_STDERR")
    ENV.delete("HIVE_FAKE_GH_STATE")
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
