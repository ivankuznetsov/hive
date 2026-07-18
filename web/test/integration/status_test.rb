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
    assert_select ".daemon-panel .task-meta", text: "running"
    assert_select ".daemon-panel", { text: /daemon is down/, count: 0 },
                  "a live hivebox supervisor intentionally has no platform service unit"
  ensure
    StatusBroadcaster.define_singleton_method(:snapshot, original_snapshot) if original_snapshot
    if original_report_new
      Hive::Daemon::StatusReport.define_singleton_method(:new, original_report_new)
    end
  end
end
