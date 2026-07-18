require "test_helper"

# The broadcaster must be self-healing: a raising broadcast (solid_cable
# hiccup, one bad row blowing up the partial) previously killed the thread
# while `@thread ||=` pinned the corpse — live updates silently froze until
# process restart, the exact failure StatusFeed's poller fix addressed one
# layer down.
class StatusBroadcasterTest < ActiveSupport::TestCase
  class FakeFeed
    def initialize
      @queue = Queue.new
    end

    def push(payload) = @queue.push(payload)

    def each_snapshot(on_idle: nil)
      loop { yield @queue.pop }
    end

    def snapshot = { "projects" => [] }
    def stop = nil
  end

  teardown do
    StatusBroadcaster.stop!
    StatusBroadcaster.feed = nil
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

    StatusBroadcaster.start!
    feed.push({ "projects" => [ { "name" => "a" } ] })  # killed the old impl
    feed.push({ "projects" => [ { "name" => "b" } ] })  # must still arrive

    payload = Timeout.timeout(5) { delivered.pop }
    assert_equal [ { "name" => "b" } ], payload["projects"],
                 "the broadcast after the failure must still be delivered"
  ensure
    StatusBroadcaster.define_singleton_method(:broadcast, original_broadcast) if original_broadcast
    StatusBroadcaster.send(:remove_const, :RETRY_SEC)
    StatusBroadcaster.const_set(:RETRY_SEC, original_retry)
  end

  test "board cursor advances and changes epoch after restart" do
    replacements = []
    refreshes = []
    StatusBroadcaster.send(:reset_stream!)
    before = StatusBroadcaster.stream_cursor

    replace = lambda do |*args, **kwargs|
      replacements << [ args, kwargs ]
    end
    refresh = lambda do |*args, **kwargs|
      refreshes << [ args, kwargs ]
    end

    original_replace = Turbo::StreamsChannel.method(:broadcast_replace_to)
    original_refresh = Turbo::StreamsChannel.method(:broadcast_refresh_to)
    Turbo::StreamsChannel.define_singleton_method(:broadcast_replace_to, replace)
    Turbo::StreamsChannel.define_singleton_method(:broadcast_refresh_to, refresh)
    StatusBroadcaster.send(:broadcast, { "projects" => [] })

    after = StatusBroadcaster.stream_cursor
    assert_equal before[:epoch], after[:epoch]
    assert_equal before[:generation] + 1, after[:generation]
    assert_equal %w[board_sync projects], replacements.map { |_args, kwargs| kwargs.fetch(:target) }
    assert_equal 1, refreshes.size

    StatusBroadcaster.stop!
    restarted = StatusBroadcaster.stream_cursor
    refute_equal after[:epoch], restarted[:epoch]
    assert_equal 0, restarted[:generation]
  ensure
    Turbo::StreamsChannel.define_singleton_method(:broadcast_replace_to, original_replace) if original_replace
    Turbo::StreamsChannel.define_singleton_method(:broadcast_refresh_to, original_refresh) if original_refresh
  end
end
