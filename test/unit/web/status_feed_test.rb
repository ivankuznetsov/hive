require "test_helper"
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

  def test_snapshot_uses_registered_projects
    with_tmp_global_config do
      feed = Hive::Web::StatusFeed.new
      payload = feed.snapshot

      assert_equal "hive-status", payload["schema"]
      assert_equal [], payload["projects"]
    end
  end

  # PERF-001/002: N concurrent /events subscribers must trigger only ONE
  # filesystem scan per tick, not one per connection. The shared poller does
  # the scan; every subscriber reads the published value.
  def test_many_subscribers_share_one_scan_per_tick
    with_tmp_global_config do
      payloads = (0..50).map { |i| { "tick" => i } }
      status = CountingStatus.new(payloads)
      feed = Hive::Web::StatusFeed.new(interval: 0.02, status_command: status)

      received = Array.new(5) { [] }
      threads = received.map do |sink|
        Thread.new do
          feed.each_snapshot do |payload|
            sink << payload
            break if sink.size >= 3
          end
        end
      end
      threads.each(&:join)
      feed.stop

      # Each subscriber saw 3 distinct ticks → at most ~3 scans were needed.
      # With a per-connection scan the count would be ~5x higher. Assert the
      # scan count stays close to the number of distinct ticks, proving the
      # scan is shared, not multiplied by subscriber count.
      received.each { |sink| assert_equal 3, sink.size, "each subscriber should receive 3 snapshots" }
      assert_operator status.calls, :<=, 6,
                      "5 subscribers over 3 ticks must not multiply the scan count (got #{status.calls})"
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
  def test_initial_snapshot_failure_publishes_empty_and_recovers
    calls = 0
    status = Object.new
    status.define_singleton_method(:json_payload) do |*|
      calls += 1
      raise "boom" if calls == 1

      { "projects" => [ { "name" => "p", "tasks" => [] } ] }
    end

    feed = Hive::Web::StatusFeed.new(interval: 0.02, status_command: status)
    _out, err = capture_io do
      first = nil
      feed.each_snapshot { |snap, _json| first = snap; break }
      assert_equal [], first.fetch("projects"),
                   "a failing FIRST snapshot must degrade to an empty grid, not crash the poller"
    end
    assert_match(/initial status snapshot failed/, err,
                 "the degradation must be observable")
  ensure
    feed&.stop
  end
end
