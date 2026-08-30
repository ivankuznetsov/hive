module Hive
  module Recovery
    # Explicit forward-only maintenance entrypoint. Ordinary runtime paths may
    # open the active schema but never create or migrate it.
    module Migration
      module_function

      def cutover(confirm:, exclusions: [], **options)
        build_cutover(options).run(confirm: confirm, exclusions: exclusions)
      end

      def bootstrap(confirm:, **options)
        build_cutover(options).bootstrap(confirm: confirm)
      end

      def resume(**options)
        build_cutover(options).resume
      end

      def inventory_runtime(**options)
        require "hive/runtime_control_plane/legacy_import"
        Hive::RuntimeControlPlane::LegacyImport.new(**options).call
      end

      def build_cutover(options)
        require "hive/runtime_control_plane/cutover"
        require "hive/runtime_control_plane/maintenance"
        values = options.dup
        state_home = values.fetch(:state_home, Hive::Paths.state_home)
        values[:services] ||= Hive::RuntimeControlPlane::MaintenanceServices.new(state_home: state_home)
        Hive::RuntimeControlPlane::Cutover.new(**values)
      end
    end
  end
end
