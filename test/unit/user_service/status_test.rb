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
end
