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
    assert_equal %w[projects board_sync], replacements.map { |_args, kwargs| kwargs.fetch(:target) }
    assert_equal 1, refreshes.size

    StatusBroadcaster.stop!
    restarted = StatusBroadcaster.stream_cursor
    refute_equal after[:epoch], restarted[:epoch]
    assert_equal 0, restarted[:generation]
  ensure
    Turbo::StreamsChannel.define_singleton_method(:broadcast_replace_to, original_replace) if original_replace
    Turbo::StreamsChannel.define_singleton_method(:broadcast_refresh_to, original_refresh) if original_refresh
  end

  test "card digests drive targeted patches without an unconditional refresh" do
    replacements = []
    refreshes = []
    old_payload = payload_with_cards(1)
    changed = Marshal.load(Marshal.dump(old_payload))
    changed.dig("projects", 0, "tasks", 0)["card_digest"] = "card1:changed"
    StatusBroadcaster.instance_variable_set(:@last_payload, old_payload)

    with_broadcast_spies(replacements, refreshes) do
      StatusBroadcaster.send(:broadcast, changed)
    end

    targets = replacements.map { |_args, kwargs| kwargs.fetch(:target) }
    assert_includes targets, "card_project_task-0"
    assert_empty refreshes
    sync = replacements.find { |_args, kwargs| kwargs[:target] == "board_sync" }.last
    assert_equal false, sync.dig(:locals, :refresh_required)
  end

  test "ten changed cards fall back to one whole band patch" do
    replacements = []
    refreshes = []
    old_payload = payload_with_cards(10)
    changed = Marshal.load(Marshal.dump(old_payload))
    changed.dig("projects", 0, "tasks").each_with_index do |card, index|
      card["card_digest"] = "card1:changed-#{index}"
    end
    StatusBroadcaster.instance_variable_set(:@last_payload, old_payload)

    with_broadcast_spies(replacements, refreshes) do
      StatusBroadcaster.send(:broadcast, changed)
    end

    targets = replacements.map { |_args, kwargs| kwargs.fetch(:target) }
    assert_includes targets, "band_project_coding"
    refute targets.any? { |target| target.start_with?("card_") }
    assert_equal 1, refreshes.size
  end

  private

  def with_broadcast_spies(replacements, refreshes)
    original_replace = Turbo::StreamsChannel.method(:broadcast_replace_to)
    original_refresh = Turbo::StreamsChannel.method(:broadcast_refresh_to)
    Turbo::StreamsChannel.define_singleton_method(:broadcast_replace_to) do |*args, **kwargs|
      replacements << [ args, kwargs ]
    end
    Turbo::StreamsChannel.define_singleton_method(:broadcast_refresh_to) do |*args, **kwargs|
      refreshes << [ args, kwargs ]
    end
    yield
  ensure
    Turbo::StreamsChannel.define_singleton_method(:broadcast_replace_to, original_replace)
    Turbo::StreamsChannel.define_singleton_method(:broadcast_refresh_to, original_refresh)
  end

  def payload_with_cards(count)
    now = Time.now.utc.iso8601
    {
      "projects" => [ {
        "name" => "project",
        "workflows" => [ { "id" => "coding", "stages" => [ { "dir" => "1-inbox" } ] } ],
        "tasks" => count.times.map do |index|
          {
            "slug" => "task-#{index}", "workflow" => "coding", "stage" => "1-inbox",
            "terminal" => false, "mtime" => now, "folder_mtime" => now,
            "card_digest" => "card1:#{index}"
          }
        end
      } ]
    }
  end
end
