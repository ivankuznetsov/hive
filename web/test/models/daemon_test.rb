require "test_helper"
require "hive/bot/dispatch_request_writer"

class DaemonTest < ActiveSupport::TestCase
  test "degrades a failed liveness probe to stopped" do
    warning = nil
    status_replacement = proc { raise "status exploded" }
    logger_replacement = proc { |message| warning = message }

    with_replaced_singleton_method(Hive::Daemon::StatusReport, :new, status_replacement) do
      with_replaced_singleton_method(Rails.logger, :warn, logger_replacement) do
        refute Daemon.new.running?
      end
    end

    assert_match(/daemon liveness probe failed: RuntimeError: status exploded/, warning)
  end

  test "queues repair through the daemon resource" do
    request_id = Daemon.new.repair!

    request = Dir[File.join(Hive::Paths.state_home, "dispatch_requests", "**", "*#{request_id}*")]
              .find { |path| File.file?(path) }
    payload = JSON.parse(File.read(request))

    assert_equal Hive::Daemon::DispatchRequestQueue::GLOBAL_MAINTENANCE_PROJECT, payload["project"]
    assert_equal %w[hive daemon install --force], payload["argv"]
    assert_equal "web_daemon_repair", payload["trigger"]
  ensure
    FileUtils.rm_rf(File.join(Hive::Paths.state_home, "dispatch_requests"))
  end

  test "turns a rejected repair request into operator guidance" do
    replacement = proc { |**| raise ArgumentError, "argv not allowlisted" }

    error = with_replaced_singleton_method(Hive::Bot::DispatchRequestWriter, :write!, replacement) do
      assert_raises(Hive::Error) { Daemon.new.repair! }
    end

    assert_match(/hive daemon install --force/, error.message)
  end
end
