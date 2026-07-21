require "test_helper"
require "hive/daemon/status_report"

class StatusTest < ActionDispatch::IntegrationTest
  test "a supervised daemon does not render service repair guidance" do
    sign_in!
    daemon_status = {
      "running" => true,
      "service_installed" => false,
      "binary_drift" => "unknown"
    }
    report = Object.new
    report.define_singleton_method(:safe_payload) { daemon_status }
    original_snapshot = StatusBroadcaster.method(:snapshot)
    original_report_new = Hive::Daemon::StatusReport.method(:new)
    StatusBroadcaster.define_singleton_method(:snapshot) { { "projects" => [] } }
    Hive::Daemon::StatusReport.define_singleton_method(:new) { report }

    get "/"

    assert_response :success
    assert_select ".daemon-panel.daemon-panel-running"
    assert_select ".daemon-summary", text: "Daemon running"
    assert_select ".daemon-panel", { text: /service installed/, count: 0 }
    assert_select ".daemon-panel", { text: /daemon is down/, count: 0 },
                  "a live hivebox supervisor intentionally has no platform service unit"
  ensure
    StatusBroadcaster.define_singleton_method(:snapshot, original_snapshot) if original_snapshot
    if original_report_new
      Hive::Daemon::StatusReport.define_singleton_method(:new, original_report_new)
    end
  end

  test "a running daemon with binary drift presents one compact repair warning" do
    sign_in!
    with_daemon_status(
      "running" => true,
      "service_installed" => true,
      "binary_drift" => "path"
    ) do
      get "/"

      assert_response :success
      assert_select ".daemon-panel.daemon-panel-warning"
      assert_select ".daemon-summary", text: "Daemon running"
      assert_select ".daemon-warning", text: "Binary path differs"
      assert_select "form button", text: "Repair"
      assert_select ".daemon-panel", { text: /binary drift|service installed/, count: 0 }
    end
  end

  test "projects with more active tasks appear first everywhere on status" do
    sign_in!
    projects = [
      { "name" => "xbookmark", "tasks" => [] },
      { "name" => "hive", "tasks" => [ { "slug" => "one" }, { "slug" => "two" } ] },
      { "name" => "webmail.sh", "tasks" => [ { "slug" => "three" } ] }
    ]
    with_daemon_status(
      "running" => true,
      "service_installed" => true,
      "binary_drift" => "none"
    ) do
      with_status_snapshot("projects" => projects) do
        get "/"

        assert_response :success
        assert_select ".project-nav button" do |buttons|
          assert_equal [ "All projects", "hive", "webmail.sh", "xbookmark" ],
                       buttons.map { |button| button.text.strip }
        end
        assert_select ".project-section" do |sections|
          assert_equal [ "hive", "webmail.sh", "xbookmark" ],
                       sections.map { |section| section["data-project-name"] }
        end
        assert_select ".composer select[name='project'] option:not([disabled])" do |options|
          assert_equal [ "hive", "webmail.sh", "xbookmark" ],
                       options.map { |option| option["value"] }
        end
      end
    end
  end

  test "board is the default and only the preference mutation changes the saved view" do
    sign_in!
    with_daemon_status(
      "running" => true,
      "service_installed" => true,
      "binary_drift" => "none"
    ) do
      get "/"

      assert_response :success
      assert_select "#status-board", 1
      assert_select "#status-grid", 0
      assert_select ".status-view-switch [aria-current='page']", text: "Board"

      get "/grid"

      assert_response :success
      assert_select "#status-grid", 1
      assert_select "#status-board", 0
      assert_select ".status-view-switch [aria-current='page']", text: "Grid"

      get "/"
      assert_select "#status-board", 1, "a plain view GET must not mutate the preference"

      post status_view_preference_path, params: { view: "grid" }
      assert_redirected_to grid_path
      follow_redirect!
      assert_select "#status-grid", 1

      get "/"
      assert_select "#status-grid", 1, "the explicit preference mutation should change the default"

      get "/board"
      assert_select "#status-board", 1

      get "/"
      assert_select "#status-grid", 1, "refreshing another view must not overwrite the saved choice"

      post status_view_preference_path, params: { view: "board" }
      assert_redirected_to board_path
      get "/"
      assert_select "#status-board", 1

      post status_view_preference_path, params: { view: "unknown" }
      assert_response :bad_request
      post status_view_preference_path
      assert_response :bad_request
      get "/"
      assert_select "#status-board", 1, "invalid mutations must not change the saved preference"
    end
  end

  test "board renders workflow columns and native task actions from the status snapshot" do
    sign_in!
    project_name = create_hive_project!("kanban-status-app")
    project_path = File.join(ENV.fetch("HIVE_TEST_HOME_ROOT"), "repos", project_name)
    projects = [
      {
        "name" => project_name,
        "path" => project_path,
        "hive_state_path" => File.join(project_path, ".hive-state"),
        "tasks" => [
          {
            "slug" => "ready-card-260721-abcd",
            "display_name" => "Ready card",
            "stage" => "3-plan",
            "workflow" => "coding",
            "marker" => "complete",
            "age_seconds" => 120
          }
        ]
      }
    ]
    with_daemon_status(
      "running" => true,
      "service_installed" => true,
      "binary_drift" => "none"
    ) do
      with_status_snapshot("projects" => projects) do
        get "/board"

        assert_response :success
        assert_select ".kanban-band[data-project-name='#{project_name}'][data-workflow='coding']"
        assert_select ".kanban-column[data-stage='3-plan'] .kanban-card", text: /Ready card/
        assert_select ".kanban-card form[action='/tasks/#{project_name}/ready-card-260721-abcd/approve'] button",
                      text: "Approve"
        assert_select ".kanban-card a[href='/tasks/#{project_name}/ready-card-260721-abcd']",
                      text: "Ready card"
      end
    end
  end

  test "status views expose degraded projects and unavailable workflows" do
    sign_in!
    project_name = create_hive_project!("kanban-degraded-status-app")
    project_path = File.join(ENV.fetch("HIVE_TEST_HOME_ROOT"), "repos", project_name)
    projects = [
      {
        "name" => project_name,
        "path" => project_path,
        "hive_state_path" => File.join(project_path, ".hive-state"),
        "tasks" => [ { "slug" => "visible-error-task", "stage" => "2-draft", "workflow" => "missing" } ]
      },
      {
        "name" => "broken-project",
        "path" => "/missing/project",
        "hive_state_path" => "/missing/project/.hive-state",
        "error" => "project_load_failed",
        "tasks" => []
      }
    ]

    with_daemon_status("running" => true, "service_installed" => true, "binary_drift" => "none") do
      with_status_snapshot("projects" => projects) do
        get board_path
        assert_select ".kanban-band[data-workflow='missing'] .state-banner", text: /Workflow unavailable/
        assert_select ".kanban-card[data-task-slug='visible-error-task']"
        assert_select ".kanban-band[data-project-name='broken-project'] .state-banner",
                      text: /Project status unavailable/

        get grid_path
        assert_select ".project-section[data-project-name='broken-project'] .state-banner",
                      text: /Project status unavailable/
      end
    end
  end


  test "a stopped installed daemon shows the command that resumes it" do
    sign_in!
    with_daemon_status(
      "running" => false,
      "service_installed" => true,
      "binary_drift" => "none"
    ) do
      get "/"

      assert_response :success
      assert_select ".daemon-panel code", text: "hive daemon start --detach"
    end
  end

  test "a stopped missing daemon service keeps install repair guidance" do
    sign_in!
    with_daemon_status(
      "running" => false,
      "service_installed" => false,
      "binary_drift" => "not_applicable"
    ) do
      get "/"

      assert_response :success
      assert_select ".daemon-panel code", text: "hive daemon install --force"
    end
  end

  private

  def with_daemon_status(payload)
    report = Object.new
    report.define_singleton_method(:safe_payload) { payload }
    original_snapshot = StatusBroadcaster.method(:snapshot)
    original_report_new = Hive::Daemon::StatusReport.method(:new)
    StatusBroadcaster.define_singleton_method(:snapshot) { { "projects" => [] } }
    Hive::Daemon::StatusReport.define_singleton_method(:new) { report }
    yield
  ensure
    StatusBroadcaster.define_singleton_method(:snapshot, original_snapshot) if original_snapshot
    Hive::Daemon::StatusReport.define_singleton_method(:new, original_report_new) if original_report_new
  end

  def with_status_snapshot(payload)
    original_snapshot = StatusBroadcaster.method(:snapshot)
    StatusBroadcaster.define_singleton_method(:snapshot) { payload }
    yield
  ensure
    StatusBroadcaster.define_singleton_method(:snapshot, original_snapshot) if original_snapshot
  end
end
