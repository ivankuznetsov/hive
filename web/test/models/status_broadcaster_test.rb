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

  test "one sorted snapshot renders every live project surface" do
    payload = {
      "projects" => [
        { "name" => "idle", "tasks" => [] },
        { "name" => "busy", "tasks" => [ {} ] }
      ]
    }
    events = []
    channel = Turbo::StreamsChannel
    original_refresh = channel.method(:broadcast_refresh_to)
    original_replace = channel.method(:broadcast_replace_to)
    channel.define_singleton_method(:broadcast_refresh_to) do |*args, **kwargs|
      events << [ :refresh, args, kwargs ]
    end
    channel.define_singleton_method(:broadcast_replace_to) do |*args, **kwargs|
      events << [ :replace, args, kwargs ]
    end

    StatusBroadcaster.send(:broadcast, payload)

    assert_equal [ :refresh, :replace, :replace ], events.map(&:first)
    assert_equal %w[project-nav composer-project],
                 events.drop(1).map { |event| event.last.fetch(:target) }
    assert_equal [
      "status/project_nav",
      "status/composer_project"
    ], events.drop(1).map { |event| event.last.fetch(:partial) }
    events.drop(1).each do |event|
      assert_equal %w[busy idle],
                   event.last.dig(:locals, :projects).map { |project| project.fetch("name") }
    end
    assert_equal({ method: :morph }, events[2].last.fetch(:attributes))
  ensure
    channel&.define_singleton_method(:broadcast_refresh_to, original_refresh) if original_refresh
    channel&.define_singleton_method(:broadcast_replace_to, original_replace) if original_replace
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
    if original_broadcast
      StatusBroadcaster.define_singleton_method(:broadcast, original_broadcast)
      StatusBroadcaster.singleton_class.send(:private, :broadcast)
    end
    StatusBroadcaster.send(:remove_const, :RETRY_SEC)
    StatusBroadcaster.const_set(:RETRY_SEC, original_retry)
  end
end
