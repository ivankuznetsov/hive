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

  test "a raising broadcast does not permanently stop live updates" do
    feed = FakeFeed.new
    StatusBroadcaster.feed = feed
    delivered = Queue.new
    calls = 0
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
    StatusBroadcaster.singleton_class.remove_method(:broadcast)
    StatusBroadcaster.send(:remove_const, :RETRY_SEC)
    StatusBroadcaster.const_set(:RETRY_SEC, original_retry)
  end
end
