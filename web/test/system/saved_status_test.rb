require "application_system_test_case"

class SavedStatusTest < ApplicationSystemTestCase
  test "saved board is visible during refresh and replaced over Cable" do
    project = create_hive_project!("saved-board-browser")
    slug = create_task!(project, "Saved task appears immediately")
    configure_owner!
    store = Hive::Web::StatusSnapshotStore.new(path: File.join(ENV.fetch("HIVE_TEST_HOME_ROOT"), "browser-status.json"))
    initial_feed = Hive::Web::StatusFeed.new(snapshot_store: store)
    payload = initial_feed.snapshot_state.payload
    original_feed = StatusBroadcaster.feed
    StatusBroadcaster.stop!
    release = Queue.new
    producer = Object.new.extend(Hive::Web::StatusCommand)
    producer.define_singleton_method(:json_payload) { |_| release.pop }
    feed = Hive::Web::StatusFeed.new(status_command: producer, snapshot_store: store, interval: 60)
    StatusBroadcaster.feed = feed
    visit "/dev_login?as=alice"
    assert_selector ".status-freshness-warning[data-status-availability=cached]", text: "Updating your workspace"
    assert_selector ".kanban-card[data-task-slug='#{slug}']", text: "Saved task appears immediately"
    [ 1280, 390 ].each do |width|
      page.current_window.resize_to(width, 850)
      assert_no_selector ".status-loading"
      assert_operator page.evaluate_script("document.documentElement.scrollWidth"), :<=, width
      page.save_screenshot(Rails.root.join("tmp", "saved-status-#{width}.png"))
    end
    release << payload
    assert_no_selector ".status-freshness-warning", wait: 10
    assert_selector ".kanban-card[data-task-slug='#{slug}']"
  ensure
    StatusBroadcaster.stop!
    StatusBroadcaster.feed = original_feed if original_feed
  end
end
