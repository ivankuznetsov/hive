require "test_helper"

# The broadcaster must be self-healing: a raising broadcast (solid_cable
# hiccup, one bad row blowing up the partial) previously killed the thread
# while `@thread ||=` pinned the corpse — live updates silently froze until
# process restart, the exact failure StatusFeed's poller fix addressed one
# layer down.
class StatusBroadcasterTest < ActiveSupport::TestCase
  class FakeFeed
    attr_reader :primes, :snapshot_calls, :archive_snapshot_calls, :stops

    def initialize(initial: { "projects" => [] }, version: "test-token")
      @queue = Queue.new
      @started = Queue.new
      @current = initial
      @version = version
      @primes = []
      @snapshot_calls = 0
      @archive_snapshot_calls = 0
      @stops = 0
    end

    def push(payload) = @queue.push(payload)

    def each_snapshot(on_idle: nil)
      @started.push(true)
      yield @current
      loop do
        @current = @queue.pop
        yield @current
      end
    end

    def wait_until_started = Timeout.timeout(2) { @started.pop }
    def snapshot
      @snapshot_calls += 1
      @current
    end

    def archive_snapshot
      @archive_snapshot_calls += 1
      @current.merge("archive" => true)
    end

    def prime(payload)
      @primes << payload
      @version
    end

    def current_version?(candidate) = candidate == @version

    def stop = @stops += 1
  end

  teardown do
    StatusBroadcaster.stop!
    StatusBroadcaster.feed = nil
  end

  test "projects are ordered by active task count with stable ties" do
    payload = {
      "projects" => [
        { "name" => "idle", "tasks" => [] },
        { "name" => "busy-first", "tasks" => [ {}, {} ] },
        { "name" => "busy-second", "tasks" => [ {}, {} ] },
        { "name" => "active", "tasks" => [ {} ] }
      ]
    }

    assert_equal %w[busy-first busy-second active idle],
                 StatusBroadcaster.projects(payload).map { |project| project["name"] }
  end

  test "the HTTP snapshot primes the exact payload handed to Cable" do
    payload = { "projects" => [ { "name" => "demo", "tasks" => [] } ] }
    feed = FakeFeed.new(initial: payload)
    StatusBroadcaster.feed = feed

    page_snapshot = StatusBroadcaster.snapshot_with_version
    assert_same payload, page_snapshot.payload
    assert_equal "test-token", page_snapshot.version
    assert_equal [ payload ], feed.primes
    assert_equal 1, feed.snapshot_calls

    StatusBroadcaster.subscriber_connected!
    feed.wait_until_started
    assert_equal 1, feed.snapshot_calls,
                 "the first subscriber must reuse the request snapshot"
  end

  test "archive snapshots bypass ordinary feed priming" do
    feed = FakeFeed.new
    StatusBroadcaster.feed = feed

    payload = StatusBroadcaster.archive_snapshot

    assert_equal true, payload.fetch("archive")
    assert_equal 1, feed.archive_snapshot_calls
    assert_empty feed.primes
    assert_equal 0, feed.snapshot_calls
  end

  test "one sorted snapshot is rendered before one live update is sent" do
    payload = {
      "projects" => [
        { "name" => "idle", "tasks" => [] },
        { "name" => "busy", "tasks" => [ {} ] }
      ]
    }
    events = []
    channel = Turbo::StreamsChannel
    render = lambda do |*args, **kwargs|
      events << [ args, kwargs ]
    end

    with_replaced_singleton_method(channel, :broadcast_render_to, render) do
      StatusBroadcaster.send(:broadcast, payload)
    end

    assert_equal 1, events.size,
                 "partial rendering and delivery must be one all-or-nothing Cable operation"
    assert_equal [ StatusBroadcaster::CHANNEL ], events.first.first
    assert_equal "status/broadcast", events.first.last.fetch(:partial)
    assert_equal %w[busy idle],
                 events.first.last.dig(:locals, :projects).map { |project| project.fetch("name") }
  end

  test "the atomic status broadcast contains refresh and the permanent project selector" do
    projects = [ Project.new("name" => "demo", "tasks" => []) ]
    content = ApplicationController.render(
      formats: [ :turbo_stream ],
      partial: "status/broadcast",
      locals: { projects: }
    )

    streams = Nokogiri::HTML.fragment(content).css("turbo-stream")
    assert_equal 2, streams.size
    assert streams.any? { |stream| stream["action"] == "refresh" }
    composer = streams.find { |stream| stream["target"] == "composer-project" }
    assert_equal "morph", composer["method"]
  end

  test "a partial render failure sends no refresh-only half update" do
    cable = ActionCable.server
    sends = 0
    render = ->(**) { raise "bad project row" }
    broadcast = ->(*) { sends += 1 }

    error = with_replaced_singleton_method(ApplicationController, :render, render) do
      with_replaced_singleton_method(cable, :broadcast, broadcast) do
        assert_raises(RuntimeError) do
          StatusBroadcaster.send(:broadcast, { "projects" => [] })
        end
      end
    end

    assert_equal "bad project row", error.message
    assert_equal 0, sends,
                 "rendering must finish before the one Action Cable delivery is attempted"
  end

  test "a raising broadcast does not permanently stop live updates" do
    feed = FakeFeed.new
    StatusBroadcaster.feed = feed
    delivered = Queue.new
    calls = 0
    original_broadcast = StatusBroadcaster.method(:broadcast)
    StatusBroadcaster.define_singleton_method(:broadcast) do |payload|
      calls += 1
      raise "boom" if calls == 1

      delivered.push(payload)
    end
    # Heal fast in tests.
    original_retry = StatusBroadcaster::RETRY_SEC
    StatusBroadcaster.send(:remove_const, :RETRY_SEC)
    StatusBroadcaster.const_set(:RETRY_SEC, 0.05)

    StatusBroadcaster.subscriber_connected!
    feed.wait_until_started
    feed.push({ "projects" => [ { "name" => "a" } ] })  # killed the old impl

    payload = Timeout.timeout(5) { delivered.pop }
    assert_equal [ { "name" => "a" } ], payload["projects"],
                 "the failed current snapshot must be retried after resubscription"
  ensure
    if original_broadcast
      StatusBroadcaster.define_singleton_method(:broadcast, original_broadcast)
      StatusBroadcaster.singleton_class.send(:private, :broadcast)
    end
    StatusBroadcaster.send(:remove_const, :RETRY_SEC)
    StatusBroadcaster.const_set(:RETRY_SEC, original_retry)
  end

  test "the first subscriber starts one poller and the last subscriber stops it" do
    feed = FakeFeed.new
    StatusBroadcaster.feed = feed

    StatusBroadcaster.subscriber_connected!
    feed.wait_until_started
    StatusBroadcaster.subscriber_connected!

    StatusBroadcaster.subscriber_disconnected!
    assert_equal 0, feed.stops, "one remaining page must keep the shared poller alive"

    StatusBroadcaster.subscriber_disconnected!
    assert_equal 1, feed.stops, "the last page leaving must stop all background scans"
  end

  test "a failed first poller acquisition does not strand the subscriber count" do
    feed = FakeFeed.new
    StatusBroadcaster.feed = feed

    error = with_replaced_singleton_method(Thread, :new, ->(*, &) { raise ThreadError, "cannot create thread" }) do
      assert_raises(ThreadError) { StatusBroadcaster.subscriber_connected! }
    end

    assert_equal "cannot create thread", error.message
    assert_equal 0, StatusBroadcaster.instance_variable_get(:@subscriber_count),
                 "a channel that never acquired a poller must not retain a lease"

    StatusBroadcaster.subscriber_connected!
    feed.wait_until_started
    StatusBroadcaster.subscriber_disconnected!

    assert_equal 0, StatusBroadcaster.instance_variable_get(:@subscriber_count)
    assert_equal 1, feed.stops,
                 "a later healthy connection must still own and release the last lease"
  end


  test "shutdown stops a feed installed while the broadcaster thread is exiting" do
    feed = FakeFeed.new
    feed_requested = Queue.new
    release_feed = Queue.new
    kill_requested = Queue.new
    release_kill = Queue.new
    original_feed = StatusBroadcaster.method(:feed)
    StatusBroadcaster.feed = nil
    StatusBroadcaster.define_singleton_method(:feed) do
      feed_requested << true
      release_feed.pop
      instance_variable_set(:@feed, feed)
    end

    StatusBroadcaster.subscriber_connected!
    Timeout.timeout(2) { feed_requested.pop }
    broadcaster = StatusBroadcaster.instance_variable_get(:@thread)
    original_kill = broadcaster.method(:kill)
    broadcaster.define_singleton_method(:kill) do
      kill_requested << true
      release_kill.pop
      original_kill.call
    end

    stopper = Thread.new { StatusBroadcaster.subscriber_disconnected! }
    Timeout.timeout(2) { kill_requested.pop }
    release_feed << true
    feed.wait_until_started
    release_kill << true
    stopper.join(2)

    refute stopper.alive?
    assert_equal 1, feed.stops,
                 "shutdown must read the lazily installed feed after joining its owner"
  ensure
    release_feed << true if release_feed&.empty?
    release_kill << true if release_kill&.empty?
    stopper&.join(2)
    StatusBroadcaster.define_singleton_method(:feed, original_feed) if original_feed
  end

  test "a failed broadcast remains pending across the last subscriber leaving" do
    feed = FakeFeed.new
    StatusBroadcaster.feed = feed
    failed = Queue.new
    delivered = Queue.new
    calls = 0
    original_broadcast = StatusBroadcaster.method(:broadcast)
    StatusBroadcaster.define_singleton_method(:broadcast) do |payload|
      calls += 1
      if calls == 1
        failed << true
        raise "boom"
      end

      delivered << payload
    end

    StatusBroadcaster.subscriber_connected!
    feed.wait_until_started
    payload = { "projects" => [ { "name" => "changed" } ] }
    feed.push(payload)
    Timeout.timeout(2) { failed.pop }

    StatusBroadcaster.subscriber_disconnected!
    StatusBroadcaster.subscriber_connected!

    assert_equal payload, Timeout.timeout(2) { delivered.pop },
                 "the replacement broadcaster must retry the failed current value"
  ensure
    if original_broadcast
      StatusBroadcaster.define_singleton_method(:broadcast, original_broadcast)
      StatusBroadcaster.singleton_class.send(:private, :broadcast)
    end
  end
end
