require "application_system_test_case"

class SavedStatusTest < ApplicationSystemTestCase
  test "saved completed cards survive a blocked refresh and update through Cable" do
    name = create_hive_project!("saved-history-browser")
    configure_owner!
    project = Project.find!(name).attributes.merge("tasks" => [])
    history = project.merge("tasks" => [ { "slug" => "earlier-completion", "display_name" => "Earlier completion",
      "stage" => "9-done", "workflow" => "coding", "action" => "archived" } ])
    newer = history.merge("tasks" => history["tasks"] + [ { "slug" => "new-completion",
      "display_name" => "New completion", "stage" => "9-done", "workflow" => "coding", "action" => "archived" } ])
    store = Hive::Web::StatusSnapshotStore.new(path: File.join(ENV.fetch("HIVE_TEST_HOME_ROOT"), "browser-history.json"))
    store.write({ "projects" => [ project ], "project_archives" => { name => history },
      "board_metadata" => Board.new([ Project.new(project).with_history(history) ]).metadata,
      "daemon_status" => { "running" => true } }, last_success_at: 1.hour.ago.iso8601)
    source = Object.new.extend(Hive::Web::StatusCommand)
    source.define_singleton_method(:json_payload) { |_| { "projects" => [ project ] } }
    entered, release = Queue.new, Queue.new
    read_history = lambda do |_|
      Hive::Workflows::Project.synchronize do
        entered << true
        release.pop
        { "projects" => [ newer ] }
      end
    end
    original_feed = StatusBroadcaster.feed
    StatusBroadcaster.stop!
    StatusBroadcaster.feed = StatusPageFeed.new(status_command: source, snapshot_store: store, interval: 60)
    ProjectArchive.request(project)
    with_replaced_singleton_method(ProjectArchive, :snapshot, read_history) do
      visit "/dev_login?as=alice"
      Timeout.timeout(10) { entered.pop }
      visit board_path(project: name)
      assert_selector "[data-stage='9-done']:not(.is-folded) [data-task-slug='earlier-completion']"
      assert_no_selector ".status-history-loading"
      assert_no_selector "[data-task-slug='new-completion']"
      release << true
      assert_selector "[data-stage='9-done']:not(.is-folded) [data-task-slug='new-completion']", wait: 15
      assert_selector "a[href='#{task_path(name, "new-completion", source: "archive")}']"
      assert_no_selector ".status-freshness-warning", wait: 10
    end
  ensure
    release << true if release
    StatusBroadcaster.stop!
    StatusBroadcaster.feed = original_feed if original_feed
  end

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
