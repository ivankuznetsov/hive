require "hive/paths"
require "hive/runtime_control_plane/activation_gate"
require "hive/runtime_control_plane/database"
require "hive/runtime_control_plane/process_registry"

module Hive
  module RuntimeControlPlane
    # Registers every ordinary top-level Hive command before command code is
    # loaded. The registration is conservative (never child-safe), so an
    # in-flight direct command makes increment-1 quiescence ineligible.
    class CommandRegistration
      class << self
        attr_reader :current

        def start!(argv:, state_home: Hive::Paths.state_home)
          return nil if exempt?(argv)

          database = Database.new(path: Hive::Paths.runtime_control_plane_path(state_home))
          diagnosis = database.diagnostics
          return nil unless diagnosis.ok?

          database.open!
          registry = ProcessRegistry.new(database: database, state_home: state_home)
          reservation = registry.reserve!(
            origin: "direct_cli", role: command_role(argv), timeout_sec: 30
          )
          registration = registry.register!(reservation.id, pid: Process.pid)
          reservation.release_fence!
          @current = new(
            database: database, registry: registry,
            reservation_id: registration.reservation_id
          )
        rescue StandardError
          reservation&.release_fence!
          database&.disconnect
          raise
        end

        def rebind_after_daemonize!
          @current&.rebind_after_daemonize!
        end

        def reset!
          @current&.disconnect
          @current = nil
        end

        def exempt?(argv)
          words = Array(argv).map(&:to_s)
          route = command(words)
          return true if %w[setup doctor version].include?(route)
          return true if words == [ "--version" ] || words == [ "-v" ]
          return true if %w[__attempt-supervise __module-hook].include?(route)

          subcommand = route && ActivationGate.subcommand_after(
            words, route, value_options: route == "daemon" ? %w[--timeout] : []
          )
          return true if route == "runtime" && [ nil, "status" ].include?(subcommand)

          route == "daemon" && %w[status quiesce resume].include?(subcommand)
        end

        def command(argv) = Array(argv).find { |arg| !arg.start_with?("-") }

        def command_role(argv)
          words = Array(argv).map(&:to_s)
          command(words) || "unknown"
        end
      end

      attr_reader :reservation_id

      def initialize(database:, registry:, reservation_id:)
        @database = database
        @registry = registry
        @reservation_id = reservation_id
        @finished = false
      end

      def rebind_after_daemonize!
        @registry.rebind!(@reservation_id, pid: Process.pid)
        self
      end

      def finish!
        return false if @finished

        @registry.mark_stopped_by_reservation!(@reservation_id, reason: "command_exited")
        @finished = true
        true
      ensure
        disconnect if @finished
      end

      def disconnect
        @database.disconnect
      rescue RuntimeControlPlane::Error, Sequel::Error
        false
      end
    end
  end
end
