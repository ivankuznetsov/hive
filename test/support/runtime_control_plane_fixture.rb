require "hive/runtime_control_plane/installation"
require_relative "non_btrfs_storage"

module HiveRuntimeControlPlaneFixture
  module_function

  def activate!(home)
    Hive::RuntimeControlPlane::Installation.setup(state_home: home)
  end
end
