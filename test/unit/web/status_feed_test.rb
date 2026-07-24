require "test_helper"
require "open3"
require "rbconfig"
require "hive/commands/init"
require "hive/commands/new"
require "hive/web/status_feed"

class StatusFeedTest < Minitest::Test
  include HiveTestHelper

  # Counts json_payload invocations and serves a script of snapshots so a
  # test can prove the shared poller scans ONCE per tick regardless of how
  # many subscribers are attached. `json_payload` is the single seam through
  # which StatusFeed#snapshot reaches the (real, but here counted) status
  # command, so every per-tick filesystem scan flows through `calls`.
  class CountingStatus
    attr_reader :calls

    def initialize(payloads)
      @payloads = payloads
      @calls = 0
      @mutex = Mutex.new
    end

    def json_payload(_projects)
      @mutex.synchronize do
        @calls += 1
        # Hold the last scripted payload once exhausted so the poller keeps
        # publishing a stable (deduped) value.
        @payloads[[ @calls - 1, @payloads.length - 1 ].min]
      end
    end
  end

  # Holds each scan behind an explicit barrier so concurrency assertions do
  # not depend on scheduler timing. `calls` counts completed scans only;
  # `max_active` detects a second poller even if both eventually dedupe to the
  # same published value.
  class ControlledStatus
    def initialize
      @started = Queue.new
      @releases = Queue.new
      @mutex = Mutex.new
      @active = 0
      @calls = 0
      @max_active = 0
    end

    def json_payload(_projects)
      @mutex.synchronize do
        @active += 1
        @max_active = [ @max_active, @active ].max
      end
      @started << true
      payload = @releases.pop
      @mutex.synchronize { @calls += 1 }
      payload
    ensure
      @mutex.synchronize { @active -= 1 }
    end

    def wait_until_started = Timeout.timeout(2) { @started.pop }
    def release(payload) = @releases << payload
    def calls = @mutex.synchronize { @calls }
    def max_active = @mutex.synchronize { @max_active }
  end

  class CountingTokenFeed < Hive::Web::StatusFeed
    attr_reader :token_calls

    def initialize(...)
      @token_calls = 0
      super
    end

    private

    def token_for(key)
      @token_calls += 1
      super
    end
  end

  def test_snapshot_uses_registered_projects
    with_tmp_global_config do
      feed = Hive::Web::StatusFeed.new
      payload = feed.snapshot

      assert_equal "hive-status", payload["schema"]
      assert_equal [], payload["projects"]
    end
  end

  def test_archive_snapshot_uses_the_lossless_status_command_without_priming_the_ordinary_feed
    with_tmp_global_config do
      ordinary = CountingStatus.new([ { "projects" => [ { "name" => "ordinary" } ] } ])
      archive = CountingStatus.new([ { "projects" => [ { "name" => "archive" } ] } ])
      feed = Hive::Web::StatusFeed.new(
        status_command: ordinary,
        archive_status_command: archive
      )

      assert_equal "archive", feed.archive_snapshot.dig("projects", 0, "name")
      assert_equal 0, ordinary.calls
      assert_equal 1, archive.calls
      refute feed.current_version?("anything"),
             "an archive read must not claim the ordinary Cable baseline"
    ensure
      feed&.stop
    end
  end

  def test_hidden_count_only_changes_are_semantic_feed_changes
    feed = Hive::Web::StatusFeed.new
    initial = {
      "projects" => [
        { "name" => "demo", "tasks" => [], "hidden_archived_task_count" => 1 }
      ]
    }
    changed = {
      "projects" => [
        { "name" => "demo", "tasks" => [], "hidden_archived_task_count" => 2 }
      ]
    }
    initial_token = feed.prime(initial)

    feed.send(:publish, changed)

    refute feed.current_version?(initial_token),
           "the web must refresh when only the hidden archive summary changes"
  ensure
    feed&.stop
  end

  def test_default_scan_interval_is_five_seconds
    assert_equal 5.0, Hive::Web::StatusFeed::DEFAULT_INTERVAL
  end

  def test_unchanged_semantic_snapshots_reuse_the_existing_token
    feed = CountingTokenFeed.new
    initial = { "projects" => [ { "name" => "demo", "generated_at" => "first" } ] }
    token = feed.prime(initial)

    feed.send(:publish, { "projects" => [ { "name" => "demo", "generated_at" => "later" } ] })

    assert_equal 1, feed.token_calls,
                 "an unchanged poll tick must not canonicalize and hash the payload again"
    assert feed.current_version?(token)

    feed.send(:publish, { "projects" => [ { "name" => "changed" } ] })
    assert_equal 2, feed.token_calls
  ensure
    feed&.stop
  end

  def test_token_digest_is_not_shadowed_by_a_hive_namespace_constant
    hive_digest = Hive.const_defined?(:Digest, false) ? Hive.const_get(:Digest) : nil
    Hive.const_set(:Digest, Module.new) unless hive_digest
    feed = Hive::Web::StatusFeed.new

    assert_match(/\Asha256:[0-9a-f]{64}\z/, feed.prime({ "projects" => [] }))
  ensure
    feed&.stop
    Hive.send(:remove_const, :Digest) unless hive_digest
  end

  def test_idle_feed_does_not_scan_without_a_subscriber
    with_tmp_global_config do
      status = CountingStatus.new([ { "projects" => [] } ])
      feed = Hive::Web::StatusFeed.new(interval: 0.01, status_command: status)

      sleep 0.05

      assert_equal 0, status.calls,
                   "constructing an idle feed must not start filesystem scans"
    ensure
      feed&.stop
    end
  end

  def test_snapshot_preserves_content_workflow_rows
    with_registered_workflow(content_workflow) do
      with_tmp_global_config do
        with_tmp_git_repo do |dir|
          capture_io { Hive::Commands::Init.new(dir, workflow: "content_fixture").call }
          capture_io { Hive::Commands::New.new(File.basename(dir), "web content row").call }

          feed = Hive::Web::StatusFeed.new
          row = feed.snapshot.fetch("projects").first.fetch("tasks").first

          assert_equal "content_fixture", row.fetch("workflow")
          assert_equal "1-inbox", row.fetch("stage")
          assert_equal "ready_to_advance", row.fetch("action")
          assert_match(/\Ahive approve /, row.fetch("suggested_command"))
        end
      end
    end
  end

  def test_snapshot_overlays_canonical_recovery_without_a_second_status_scan
    with_tmp_global_config do
      base = {
        "generated_at" => Time.utc(2026, 7, 25, 12).iso8601(6),
        "projects" => [
          {
            "name" => "demo",
            "tasks" => [ { "slug" => "failed-task", "marker" => "error" } ]
          }
        ]
      }
      status = CountingStatus.new([ base ])
      receipt = {
        "status" => "queued",
        "request_id" => "recovery-1",
        "attempt_id" => nil,
        "phase" => "admitted"
      }
      status.define_singleton_method(:operational_recoveries) do |_projects, status_payload:|
        raise "status payload was rescanned" unless status_payload.equal?(base)

        [
          {
            "identity" => { "project" => "demo", "slug" => "failed-task" },
            "recovery" => receipt
          }
        ]
      end
      feed = Hive::Web::StatusFeed.new(status_command: status)

      payload = feed.snapshot

      assert_equal 1, status.calls
      assert_equal receipt,
                   payload.dig("projects", 0, "tasks", 0, "recovery")
    ensure
      feed&.stop
    end
  end

  def test_snapshot_falls_back_to_base_status_when_recovery_overlay_fails
    with_tmp_global_config do
      base = {
        "generated_at" => Time.utc(2026, 7, 25, 12).iso8601(6),
        "projects" => []
      }
      status = CountingStatus.new([ base ])
      status.define_singleton_method(:operational_recoveries) do |*_args, **_kwargs|
        raise IOError, "owner snapshot unreadable"
      end
      feed = Hive::Web::StatusFeed.new(status_command: status)

      _out, err = capture_io do
        assert_same base, feed.snapshot
      end

      assert_includes err, "operational recovery overlay failed"
      assert_includes err, "owner snapshot unreadable"
    ensure
      feed&.stop
    end
  end

  # PERF-001/002: N concurrent /events subscribers must trigger only ONE
  # filesystem scan per tick, not one per connection. The shared poller does
  # the scan; every subscriber reads the published value.
  def test_many_subscribers_share_one_scan_per_tick
    with_tmp_global_config do
      status = ControlledStatus.new
      feed = Hive::Web::StatusFeed.new(interval: 0.01, status_command: status)
      ticks = (0..2).map { |tick| { "tick" => tick } }
      feed.prime(ticks.first)
      deliveries = Queue.new
      received = Array.new(5) { [] }
      threads = received.each_index.map do |index|
        Thread.new do
          count = 0
          feed.each_snapshot do |payload|
            deliveries << [ index, payload ]
            count += 1
            break if count == ticks.size
          end
        end
      end

      receive_round = lambda do
        received.size.times do
          index, payload = Timeout.timeout(2) { deliveries.pop }
          received.fetch(index) << payload
        end
      end

      receive_round.call
      status.wait_until_started
      status.release(ticks.fetch(1))
      receive_round.call
      status.wait_until_started
      status.release(ticks.fetch(2))
      receive_round.call

      threads.each do |thread|
        thread.join(2)
        refute thread.alive?, "every subscriber must finish after the third shared snapshot"
      end
      feed.stop

      received.each { |snapshots| assert_equal ticks, snapshots }
      assert_equal 2, status.calls,
                   "two changed poll ticks must perform exactly two shared scans"
      assert_equal 1, status.max_active,
                   "subscriber fan-out must never create overlapping pollers"
    ensure
      threads&.each(&:kill)
      threads&.each { |thread| thread.join(2) }
      feed&.stop
    end
  end

  # Emit-on-connect: a brand-new subscriber must receive the current snapshot
  # immediately, before any further tick.
  def test_emit_on_connect_yields_current_snapshot_immediately
    with_tmp_global_config do
      status = CountingStatus.new([ { "tick" => "first" } ])
      feed = Hive::Web::StatusFeed.new(interval: 5.0, status_command: status)

      first = nil
      thread = Thread.new do
        feed.each_snapshot do |payload|
          first = payload
          break
        end
      end
      thread.join(2)
      feed.stop

      refute thread.alive?, "emit-on-connect must yield without waiting a full interval"
      assert_equal({ "tick" => "first" }, first)
    end
  end

  def test_first_primed_page_snapshot_becomes_the_poller_baseline_without_a_second_scan
    with_tmp_global_config do
      payload = { "projects" => [ { "name" => "demo", "tasks" => [] } ] }
      status = CountingStatus.new([ payload ])
      feed = Hive::Web::StatusFeed.new(interval: 5.0, status_command: status)
      page_snapshot = feed.snapshot

      page_token = feed.prime(page_snapshot)
      assert feed.current_version?(page_token)
      replacement = { "projects" => [ { "name" => "newer", "tasks" => [] } ] }
      replacement_token = feed.prime(replacement)
      refute_equal page_token, replacement_token,
                   "each page must be stamped with the token for what it rendered"
      refute feed.current_version?(replacement_token),
             "a competing render must not inherit the active baseline's identity"

      seen = nil
      subscriber = Thread.new do
        feed.each_snapshot do |snapshot|
          seen = snapshot
          break
        end
      end
      subscriber.join(2)

      refute subscriber.alive?
      assert_equal page_snapshot, seen
      assert_equal 1, status.calls,
                   "starting the poller must reuse the page render instead of scanning the fleet again"
      assert_equal page_token, feed.prime(payload),
                   "a request must not replace the running poller's value"
    ensure
      subscriber&.kill
      subscriber&.join
      feed&.stop
    end
  end

  def test_competing_idle_prime_arrives_as_a_changed_tick_for_the_earlier_page
    with_tmp_global_config do
      earlier = { "projects" => [ { "name" => "earlier", "tasks" => [] } ] }
      newer = { "projects" => [ { "name" => "newer", "tasks" => [] } ] }
      feed = Hive::Web::StatusFeed.new(
        interval: 0.02,
        status_command: CountingStatus.new([ newer ])
      )

      earlier_token = feed.prime(earlier)
      newer_token = feed.prime(newer)
      refute_equal earlier_token, newer_token,
                   "different rendered content must never share one freshness token"
      seen = []
      subscriber = Thread.new do
        feed.each_snapshot do |snapshot|
          seen << snapshot
          break if seen.size == 2
        end
      end
      subscriber.join(2)

      refute subscriber.alive?
      assert_equal [ earlier, newer ], seen,
                   "the first poll must broadcast the snapshot rejected as a competing prime"
      refute feed.current_version?(earlier_token),
             "a page that connects after this tick must be recognized as stale"
      assert feed.current_version?(newer_token)
    ensure
      subscriber&.kill
      subscriber&.join
      feed&.stop
    end
  end

  # Dedup + keep-alive: an unchanged snapshot is suppressed (not re-yielded)
  # and instead fires on_idle so the route can emit its SSE keep-alive.
  def test_unchanged_snapshot_is_deduped_and_fires_on_idle
    with_tmp_global_config do
      # Same payload forever → after the connect emit, every tick is a dup.
      status = CountingStatus.new([ { "stable" => true } ])
      feed = Hive::Web::StatusFeed.new(interval: 0.02, status_command: status)

      yields = []
      idles = 0
      idle_mutex = Mutex.new
      thread = Thread.new do
        feed.each_snapshot(on_idle: -> { idle_mutex.synchronize { idles += 1 } }) do |payload|
          yields << payload
          # Keep running so several idle ticks accumulate.
          Thread.current[:done] = true if idle_mutex.synchronize { idles } >= 3
          break if Thread.current[:done]
        end
      end
      thread.join(3)
      feed.stop
      thread.kill if thread.alive?

      assert_equal [ { "stable" => true } ], yields,
                   "an unchanged snapshot must be yielded only once (the connect emit)"
      assert_operator idle_mutex.synchronize { idles }, :>=, 1,
                      "unchanged ticks must fire on_idle for the keep-alive"
    end
  end

  # Two independent subscribers that connect at different times must EACH get
  # the current published value on connect (no shared dedup cursor starving a
  # late joiner).
  def test_independent_subscribers_each_get_current_value_on_connect
    with_tmp_global_config do
      status = CountingStatus.new([ { "v" => 1 } ])
      feed = Hive::Web::StatusFeed.new(interval: 5.0, status_command: status)

      a = nil
      ta = Thread.new { feed.each_snapshot { |p| a = p; break } }
      ta.join(2)

      b = nil
      tb = Thread.new { feed.each_snapshot { |p| b = p; break } }
      tb.join(2)
      feed.stop

      refute ta.alive?
      refute tb.alive?
      assert_equal({ "v" => 1 }, a, "first subscriber gets the snapshot on connect")
      assert_equal({ "v" => 1 }, b, "a later subscriber also gets the current snapshot on connect")
    end
  end

  def test_stop_is_safe_without_a_running_poller
    with_tmp_global_config do
      feed = Hive::Web::StatusFeed.new
      feed.stop # no subscriber ever started the poller
    end
  end

  def test_stop_without_a_poller_releases_the_idle_page_claim
    with_tmp_global_config do
      feed = Hive::Web::StatusFeed.new
      first = feed.prime({ "projects" => [ { "name" => "first" } ] })

      feed.stop
      second = feed.prime({ "projects" => [ { "name" => "second" } ] })

      refute_equal first, second,
                   "an abandoned pre-Cable page must not strand the next lifecycle's baseline"
      assert feed.current_version?(second)
    ensure
      feed&.stop
    end
  end

  def test_stopping_poller_does_not_clear_a_new_claim_accepted_while_joining
    with_tmp_global_config do
      feed = Hive::Web::StatusFeed.new(
        interval: 5.0,
        status_command: CountingStatus.new([ { "projects" => [] } ])
      )
      feed.each_snapshot { break }
      poller = feed.instance_variable_get(:@poller)
      kill_requested = Queue.new
      release_kill = Queue.new
      original_kill = poller.method(:kill)
      poller.define_singleton_method(:kill) do
        kill_requested << true
        release_kill.pop
        original_kill.call
      end

      stopper = Thread.new { feed.stop }
      Timeout.timeout(2) { kill_requested.pop }
      claimed_token = feed.prime({ "projects" => [ { "name" => "new lifecycle" } ] })
      release_kill << true
      stopper.join(2)

      refute stopper.alive?
      competing_token = feed.prime({ "projects" => [ { "name" => "must not overwrite" } ] })
      assert feed.current_version?(claimed_token),
             "the old stop must not clear the new lifecycle's claim"
      refute feed.current_version?(competing_token),
             "a competing render must not replace that preserved claim"
    ensure
      release_kill << true if release_kill&.empty?
      stopper&.join(2)
      feed&.stop
    end
  end

  def test_semantic_tokens_are_stable_across_processes_and_hash_key_order
    with_tmp_global_config do
      same_feed = Hive::Web::StatusFeed.new
      changed_feed = Hive::Web::StatusFeed.new
      first = { "schema" => "hive-status", "projects" => [ { "name" => "demo", "tasks" => [] } ] }
      reordered = { "projects" => [ { "tasks" => [], "name" => "demo" } ], "schema" => "hive-status" }
      changed = { "schema" => "hive-status", "projects" => [ { "name" => "other", "tasks" => [] } ] }

      first_token = status_token_in_fresh_process(first)
      same_token = status_token_in_fresh_process(reordered)
      changed_token = status_token_in_fresh_process(changed)
      same_feed.prime(reordered)
      changed_feed.prime(changed)

      assert_match(/\Asha256:[0-9a-f]{64}\z/, first_token)
      assert_equal first_token, same_token,
                   "equal semantic snapshots must agree across independent Puma workers"
      refute_equal first_token, changed_token,
                   "different first snapshots must not collide after a process restart"
      assert same_feed.current_version?(first_token)
      refute changed_feed.current_version?(first_token)
      refute changed_feed.current_version?(1),
             "untrusted numeric counters from older pages must fail closed"
    ensure
      same_feed&.stop
      changed_feed&.stop
    end
  end

  # A status command whose payloads differ ONLY in the volatile fields
  # json_payload regenerates every scan (generated_at, per-task age_seconds).
  # Byte-comparing payloads made the documented dedup dead in production:
  # every tick re-emitted and the on_idle keep-alive never ran.
  def test_dedup_ignores_volatile_timestamp_fields
    with_tmp_global_config do
      payloads = (1..6).map do |n|
        { "schema" => "hive-status", "generated_at" => "2026-06-10T0#{n}:00:00Z",
          "projects" => [ { "name" => "demo",
                            "tasks" => [ { "slug" => "t", "age_seconds" => n * 10 } ] } ] }
      end
      feed = Hive::Web::StatusFeed.new(interval: 0.02, status_command: CountingStatus.new(payloads))
      page_version = feed.prime(feed.snapshot)
      yields = 0
      idles = 0
      idle_mutex = Mutex.new
      subscriber = Thread.new do
        feed.each_snapshot(on_idle: -> { idle_mutex.synchronize { idles += 1 } }) do |_payload|
          yields += 1
        end
      end
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 5
      sleep 0.01 until idle_mutex.synchronize { idles } >= 2 ||
                       Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

      assert_operator idle_mutex.synchronize { idles }, :>=, 2,
                      "unchanged-but-for-timestamps ticks must fire on_idle (dedup dead otherwise)"
      assert_equal 1, yields,
                   "payloads differing only in generated_at/age_seconds must dedup to the connect emit"
      assert feed.current_version?(page_version),
             "volatile-only ticks must not make a current page look stale on reconnect"
    ensure
      subscriber&.kill
      subscriber&.join
      feed&.stop
    end
  end

  # A transient snapshot failure (config mid-edit, a task folder mv racing
  # the scan) must not kill the shared poller: a dead poller stops ticks,
  # which silently freezes every subscriber AND the on_idle keep-alive path.
  class FlakyOnceStatus
    def initialize(payloads)
      @payloads = payloads
      @calls = 0
      @mutex = Mutex.new
    end

    def json_payload(_projects)
      @mutex.synchronize do
        @calls += 1
        raise Hive::ConfigError, "config.yml is mid-edit" if @calls == 2

        @payloads[[ @calls - 1, @payloads.length - 1 ].min]
      end
    end
  end

  def test_poller_survives_a_snapshot_error_and_keeps_publishing
    with_tmp_global_config do
      first = { "projects" => [ { "name" => "demo", "tasks" => [] } ] }
      second = { "projects" => [ { "name" => "demo", "tasks" => [ { "slug" => "new" } ] } ] }
      feed = Hive::Web::StatusFeed.new(interval: 0.02, status_command: FlakyOnceStatus.new([ first, second ]))
      seen = []
      seen_mutex = Mutex.new
      subscriber = Thread.new do
        capture_io do
          feed.each_snapshot { |payload| seen_mutex.synchronize { seen << payload } }
        end
      end
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 5
      sleep 0.01 until seen_mutex.synchronize { seen.length } >= 2 ||
                       Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

      assert_equal 2, seen_mutex.synchronize { seen.length },
                   "the poller must outlive a raising snapshot and publish the next change"
      assert_equal second, seen_mutex.synchronize { seen.last },
                   "the post-error snapshot must reach the subscriber"
    ensure
      subscriber&.kill
      subscriber&.join
      feed&.stop
    end
  end
  def test_initial_snapshot_failure_is_explicitly_unavailable_and_recovers
    calls = 0
    status = Object.new
    status.define_singleton_method(:json_payload) do |*|
      calls += 1
      raise "boom" if calls == 1

      { "projects" => [ { "name" => "p", "tasks" => [] } ] }
    end

    feed = Hive::Web::StatusFeed.new(interval: 0.02, status_command: status)
    snapshots = Queue.new
    subscriber = nil
    _out, err = capture_io do
      subscriber = Thread.new do
        count = 0
        feed.each_snapshot do |snapshot|
          snapshots << snapshot
          count += 1
          break if count == 2
        end
      end
      Timeout.timeout(2) { subscriber.value }
    end
    first = snapshots.pop(true)
    recovered = snapshots.pop(true)

    assert_equal false, first.fetch("ok")
    assert_equal true, first.fetch("unavailable"),
                 "a failing first scan must not claim that an empty fleet is healthy"
    assert_equal [], first.fetch("projects"),
                 "the unavailable envelope keeps a bounded projects shape for old payload consumers"
    assert_equal [ { "name" => "p", "tasks" => [] } ], recovered.fetch("projects"),
                 "the next successful scan must replace the empty fallback"
    assert_match(/status snapshot failed/, err,
                 "the degradation must be observable")
  ensure
    subscriber&.kill
    subscriber&.join(2)
    feed&.stop
  end

  def test_concurrent_http_refreshes_coalesce_to_one_scan
    with_tmp_global_config do
      status = ControlledStatus.new
      feed = Hive::Web::StatusFeed.new(interval: 5, status_command: status)
      states = Queue.new
      threads = 6.times.map do
        Thread.new { states << feed.snapshot_state }
      end

      status.wait_until_started
      sleep 0.02
      status.release({ "projects" => [ { "name" => "shared" } ] })
      threads.each { |thread| thread.join(2) }

      assert threads.none?(&:alive?)
      assert_equal 1, status.calls
      assert_equal 1, status.max_active
      assert_equal 1, feed.scan_count
      delivered = 6.times.map { states.pop(true) }
      assert delivered.all?(&:fresh?)
      assert_equal 1, delivered.map(&:token).uniq.size
    ensure
      threads&.each(&:kill)
      threads&.each { |thread| thread.join(2) }
      feed&.stop
    end
  end

  def test_failure_after_good_data_is_degraded_until_a_fresh_token_recovers
    calls = 0
    first = { "projects" => [ { "name" => "demo", "tasks" => [] } ] }
    second = { "projects" => [ { "name" => "demo", "tasks" => [ { "slug" => "new" } ] } ] }
    status = Object.new
    status.define_singleton_method(:json_payload) do |*|
      calls += 1
      raise "mid-edit" if calls == 2

      calls == 1 ? first : second
    end
    times = [
      Time.utc(2026, 7, 25, 10),
      Time.utc(2026, 7, 25, 11)
    ]
    feed = Hive::Web::StatusFeed.new(
      status_command: status,
      clock: -> { times.shift || Time.utc(2026, 7, 25, 12) }
    )

    fresh = feed.snapshot_state
    _out, _err = capture_io { @degraded_state = feed.snapshot_state }
    recovered = feed.snapshot_state

    assert fresh.fresh?
    assert @degraded_state.degraded?
    assert_same first, @degraded_state.payload
    assert_equal fresh.last_success_at, @degraded_state.last_success_at
    refute_equal fresh.token, @degraded_state.token
    assert recovered.fresh?
    assert_same second, recovered.payload
    refute_equal @degraded_state.token, recovered.token
    assert_equal 3, feed.scan_count
  ensure
    feed&.stop
  end

  def test_reconnecting_subscribers_reuse_current_state_without_a_scan
    with_tmp_global_config do
      status = CountingStatus.new([ { "projects" => [] } ])
      feed = Hive::Web::StatusFeed.new(interval: 5, status_command: status)
      first = feed.snapshot_state

      2.times do
        subscriber = Thread.new { feed.each_state { break } }
        subscriber.join(2)
        refute subscriber.alive?
      end

      assert first.fresh?
      assert_equal 1, status.calls
      assert_equal 1, feed.scan_count
    ensure
      feed&.stop
    end
  end

  def test_state_serializes_every_public_field
    state = Hive::Web::StatusFeed::State.new(
      payload: { "projects" => [] },
      availability: "fresh",
      token: "sha256:demo",
      last_success_at: "2026-07-26T03:00:00.000000Z",
      error: nil,
      scan_count: 2,
      generation: 3
    )

    assert_equal(
      {
        "payload" => { "projects" => [] },
        "availability" => "fresh",
        "token" => "sha256:demo",
        "last_success_at" => "2026-07-26T03:00:00.000000Z",
        "error" => nil,
        "scan_count" => 2,
        "generation" => 3
      },
      state.to_h
    )
  end

  def test_each_state_reports_idle_ticks_and_then_yields_a_changed_state
    first = { "projects" => [ { "name" => "demo" } ] }
    second = { "projects" => [ { "name" => "changed" } ] }
    status = CountingStatus.new([ first, first, second ])
    feed = Hive::Web::StatusFeed.new(interval: 0.01, status_command: status)
    idle = Queue.new
    delivered = Queue.new

    subscriber = Thread.new do
      feed.each_state(on_idle: -> { idle << true }) do |state|
        delivered << state
        break if state.payload == second
      end
    end

    first_state = Timeout.timeout(2) { delivered.pop }
    Timeout.timeout(2) { idle.pop }
    second_state = Timeout.timeout(2) { delivered.pop }
    subscriber.join(2)

    refute subscriber.alive?
    assert_equal first, first_state.payload
    assert_equal second, second_state.payload
    assert_same second_state, feed.current_state
    assert_operator status.calls, :>=, 3
  ensure
    subscriber&.kill
    subscriber&.join(2)
    feed&.stop
  end

  private

  def status_token_in_fresh_process(payload)
    lib = File.expand_path("../../../lib", __dir__)
    script = <<~'RUBY'
      require "json"
      require "hive/web/status_feed"

      feed = nil
      begin
        feed = Hive::Web::StatusFeed.new
        puts feed.prime(JSON.parse($stdin.read))
      ensure
        feed&.stop
      end
    RUBY
    out, err, status = Open3.capture3(
      RbConfig.ruby, "-I", lib, "-e", script,
      stdin_data: JSON.generate(payload)
    )

    assert status.success?, "fresh status-token process failed: #{err}"
    out.strip
  end
end
