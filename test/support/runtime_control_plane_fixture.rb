require "hive/runtime_control_plane/cutover"

module HiveRuntimeControlPlaneFixture
  class Services
    def stop!(cutover_id:) = true

    def activate!
      @activated = true
    end

    def activated? = @activated == true
  end

  class Gate
    def synchronize
      yield
    end
  end

  module_function

  def activate!(home)
    Hive::RuntimeControlPlane::Cutover.bootstrap(
      confirm: true,
      state_home: home,
      data_home: home,
      projects: [],
      services: Services.new,
      maintenance_gate: Gate.new
    )
  end
end
