require "test_helper"
require "hive/user_service/status"

class UserServiceStatusTest < Minitest::Test
  def test_legacy_boolean_manager_availability_maps_to_available
    status = Hive::UserService::Status.new(
      platform: :linux,
      unit_path: "/tmp/hive-test.service",
      content_state: :absent,
      file_identity: nil,
      manager_available: true,
      enabled: false,
      running: false
    )

    assert_equal :available, status.manager_availability
    assert status.manager_available?
  end

  def test_unknown_manager_availability_is_rejected
    error = assert_raises(ArgumentError) do
      Hive::UserService::Status.new(
        platform: :linux,
        unit_path: "/tmp/hive-test.service",
        content_state: :absent,
        file_identity: nil,
        manager_availability: :maybe,
        enabled: false,
        running: false
      )
    end

    assert_match(/unknown manager availability/, error.message)
  end

  def test_deactivating_linux_process_is_not_conclusively_stopped
    status = Hive::UserService::Status.new(
      platform: :linux,
      unit_path: "/tmp/hive-test.service",
      content_state: :matching,
      file_identity: { digest: "a" * 64 },
      manager_available: true,
      enabled: false,
      running: false,
      active_state: "deactivating",
      main_pid: 123,
      process_start: "draining"
    )

    refute status.running?
    refute status.stopped?
    assert status.process_live?
  end

  def test_transitional_manager_state_is_not_stopped_after_main_pid_clears
    status = Hive::UserService::Status.new(
      platform: :linux,
      unit_path: "/tmp/hive-test.service",
      content_state: :matching,
      file_identity: { digest: "a" * 64 },
      manager_available: true,
      enabled: false,
      running: false,
      active_state: "deactivating",
      main_pid: 0
    )

    refute status.stopped?
  end
end
