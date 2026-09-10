require "hive/runtime_control_plane/installation"

module HiveRuntimeControlPlaneFixture
  module_function

  def activate!(home)
    Hive::RuntimeControlPlane::Installation.setup(state_home: home)
  end
end
