require "test_helper"
require "hive/pid_file"

class HealthTest < ActionDispatch::IntegrationTest
  include Hive::PidFile

  def pid_file
    File.join(Hive::Paths.state_home, ".daemon.pid")
  end

  test "plain health is web liveness only" do
    get "/health"
    assert_response :success
    assert_equal true, response.parsed_body["ok"]
  end

  test "deep health is 503 while the daemon is down" do
    FileUtils.rm_f(pid_file)
    get "/health", params: { deep: "1" }
    assert_response :service_unavailable
    assert_equal false, response.parsed_body.dig("daemon", "running"),
                 "a missing daemon must be visible to the container healthcheck"
  end

  test "deep health is 200 with a live, owned daemon pidfile" do
    # The test process itself plays the daemon: a payload with OUR pid and
    # real start time passes the same liveness + ownership checks
    # `hive daemon status` applies.
    FileUtils.mkdir_p(File.dirname(pid_file))
    File.write(pid_file, pid_file_payload(Process.pid).to_yaml)
    get "/health", params: { deep: "1" }
    assert_response :success
    assert_equal Process.pid, response.parsed_body.dig("daemon", "pid")
  ensure
    FileUtils.rm_f(pid_file)
  end
end
