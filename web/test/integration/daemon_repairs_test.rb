require "test_helper"

class DaemonRepairsTest < ActionDispatch::IntegrationTest
  test "repair is a resource create that queues global maintenance" do
    sign_in!
    before = Dir[File.join(Hive::Paths.state_home, "dispatch_requests", "*.json")]

    post daemon_repair_path

    assert_redirected_to root_path
    created = Dir[File.join(Hive::Paths.state_home, "dispatch_requests", "*.json")] - before
    request = created.find { |path| JSON.parse(File.read(path))["trigger"] == "web_daemon_repair" }
    assert request, "repair must add a global maintenance request"
    payload = JSON.parse(File.read(request))
    assert_equal %w[hive daemon install --force], payload["argv"]
    assert_equal "web_daemon_repair", payload["trigger"]
  ensure
    Array(created).each { |path| FileUtils.rm_f(path) }
  end
end
