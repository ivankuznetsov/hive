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
      CHILD_RESERVATION_ENV = "HIVE_RUNTIME_CHILD_RESERVATION_ID"
      LAUNCH_GATE_ENV = "HIVE_LAUNCH_GATE_FD"

      class << self
        attr_reader :current

        def start!(argv:, state_home: Hive::Paths.state_home)
          inherited_reservation_id = ENV.delete(CHILD_RESERVATION_ENV)
          return nil if inherited_reservation_id.nil? && exempt?(argv)

          database = Database.new(path: Hive::Paths.runtime_control_plane_path(state_home))
          diagnosis = database.diagnostics
          unless diagnosis.ok?
            if inherited_reservation_id
              raise diagnosis.error || Unavailable.new(
                "runtime control plane disappeared during launch handoff",
                code: :launch_handoff_unavailable, action: "stop the process and retry"
              )
            end
            return nil
          end

          database.open!
          registry = ProcessRegistry.new(database: database, state_home: state_home)
          if inherited_reservation_id
            registration = registry.adopt!(inherited_reservation_id, pid: Process.pid)
          else
            reservation = registry.reserve!(
              origin: "direct_cli", role: command_role(argv), timeout_sec: 30
            )
            registration = registry.register!(reservation.id, pid: Process.pid)
            reservation.release_fence!
          end
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

        def spawn_registered_hive!(*argv, role:, spawner: Process.method(:spawn), **options)
          if @current
            @current.spawn_registered_hive!(*argv, role: role, spawner: spawner, **options)
          else
            spawner.call(*argv, **options)
          end
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

          ActivationGate.strict_no_write_route?(words)
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

      # Reserve before Process.spawn, register the child while it is blocked at
      # bin/hive's launch gate, then let it adopt the same row. If this parent
      # dies in the handoff, the unresolved reservation/registration remains
      # durable and quiescence fails closed rather than overlooking a child.
      def spawn_registered_hive!(*argv, role:, spawner: Process.method(:spawn), **options)
        reader, writer = IO.pipe
        reader.close_on_exec = false
        reservation = @registry.reserve!(
          origin: "direct_cli", role: role, timeout_sec: 30
        )
        environment = {
          LAUNCH_GATE_ENV => reader.fileno.to_s,
          CHILD_RESERVATION_ENV => reservation.id
        }
        spawn_options = options.merge(reader.fileno => reader.fileno, close_others: true)
        pid = spawner.call(environment, *argv, **spawn_options)
        reader.close
        @registry.register!(reservation.id, pid: pid)
        writer.write("1")
        pid
      rescue StandardError
        begin
          writer&.write("0")
        rescue Errno::EPIPE, IOError
          nil
        end
        if reservation && pid.nil?
          @registry.mark_stopped_by_reservation!(
            reservation.id, reason: "spawn_failed"
          )
        end
        raise
      ensure
        reservation&.release_fence!
        reader&.close unless reader&.closed?
        writer&.close unless writer&.closed?
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
