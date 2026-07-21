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
