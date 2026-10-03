require "hive/paths"
require "hive/runtime_control_plane/activation_gate"

module Hive
  module RuntimeControlPlane
    # One-shot CLI authority for the operational-status read-only fallback.
    # The context is thread/process scoped and bound to one runtime database;
    # long-lived in-process Status callers never create it.
    module OperationalInspection
      THREAD_KEY = :hive_runtime_operational_inspection

      module_function

      def activate_from_failure(error:, argv:, state_home:, inherited_reservation: false,
                                database: nil)
        return false if inherited_reservation
        return false unless error.is_a?(Unavailable) && error.code == :state_storage_read_only
        return false unless ActivationGate.operational_inspection_route?(argv)

        root = File.expand_path(state_home)
        database ||= Database.new(path: Hive::Paths.runtime_control_plane_path(root))
        return false unless database.confirmed_read_only_storage?

        Thread.current[THREAD_KEY] = {
          owner_pid: Process.pid,
          state_home: root,
          database_path: File.expand_path(database.path)
        }.freeze
        true
      end

      def active?
        context = current
        context && context.fetch(:owner_pid) == Process.pid
      end

      def active_for?(database_path)
        active? && current.fetch(:database_path) == File.expand_path(database_path)
      end

      def clear!
        !Thread.current[THREAD_KEY].nil?
      ensure
        Thread.current[THREAD_KEY] = nil
      end

      def current = Thread.current[THREAD_KEY]
      private_class_method :current
    end
  end
end
