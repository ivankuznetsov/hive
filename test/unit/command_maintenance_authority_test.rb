# frozen_string_literal: true

require "test_helper"
require "hive/command_maintenance_authority"

class CommandMaintenanceAuthorityTest < Minitest::Test
  include HiveTestHelper

  def test_local_authority_requires_private_nonsymlink_directory_custody
    with_tmp_dir do |root|
      state = File.join(root, "state")
      Dir.mkdir(state, 0o700)
      with_replaced_singleton_method(Hive::Paths, :state_home, -> { state }) do
        authority = Hive::CommandMaintenanceAuthority.local(principal: "owner")
        assert authority.installation_owner?
        assert_equal Process.euid, authority.custody_uid

        File.chmod(0o755, state)
        assert_raises(Hive::ConfigError) do
          Hive::CommandMaintenanceAuthority.local(principal: "owner")
        end
      end
    end
  end

  def test_loopback_records_origin_and_cannot_be_changed_by_forwarded_labels
    with_tmp_dir do |root|
      state = File.join(root, "state")
      Dir.mkdir(state, 0o700)
      database = Struct.new(:installation_identity).new({ installation_id: "install-1" })
      with_replaced_singleton_method(Hive::Paths, :state_home, -> { state }) do
        authority = Hive::CommandMaintenanceAuthority.loopback(
          database: database, peer_address: "127.0.0.1"
        )
        assert_equal "local_loopback", authority.principal_source
        assert_equal "127.0.0.1", authority.peer_address
        assert_equal "installation:install-1:uid:#{Process.euid}", authority.principal
        assert authority.installation_owner?
        assert_raises(Hive::ConfigError) do
          Hive::CommandMaintenanceAuthority.loopback(
            database: database, peer_address: "203.0.113.9"
          )
        end
      end
    end
  end

  def test_nonowner_can_maintain_only_own_receipts
    authority = Hive::CommandMaintenanceAuthority.new(
      principal: "caller", principal_source: "injected"
    )
    assert_equal "own_receipt", authority.authorize!("caller")
    assert_raises(Hive::ConfigError) { authority.authorize!("someone-else") }
  end
end
