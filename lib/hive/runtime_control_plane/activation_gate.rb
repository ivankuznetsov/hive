require "yaml"
require "hive/paths"
require "hive/runtime_control_plane"
require "hive/runtime_control_plane/cutover"

module Hive
  module RuntimeControlPlane
    # Read-only process-start gate. It runs before any scheduler reconciliation
    # or command setup so an installed candidate cannot mutate legacy authority
    # until the explicit fleet cutover has activated SQL.
    module ActivationGate
      GLOBAL_LEGACY_PATHS = %w[
        dispatch_requests dispatch_results attempts provider-health operational .task-counter.lock task-counter.yml
      ].freeze
      DATA_LEGACY_PATHS = %w[usage.db usage.db-wal usage.db-shm usage.db.patrol-discovery-allowances].freeze
      SERVICE_ACTIVATION_WAIT_SEC = 30

      module_function

      def check!(argv: ARGV, state_home: Hive::Paths.state_home,
                 data_home: Hive::Paths.data_home, config_home: Hive::Paths.config_home,
                 before_allow: nil, sleeper: ->(seconds) { sleep(seconds) },
                 monotonic_clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) })
        argv = Array(argv).map(&:to_s)
        route = command(argv)
        return allow(before_allow) if version_route?(argv) || route == "version"
        status = runtime_status(state_home)
        return allow(before_allow) if active_status?(status)
        if managed_service_route?(argv) && status["phase"] == "intended"
          wait_for_active!(state_home, sleeper: sleeper, monotonic_clock: monotonic_clock)
          return allow(before_allow)
        end
        incomplete = database_present?(state_home) || cutover_present?(state_home)
        legacy = legacy_present?(state_home, data_home, config_home)
        return allow(before_allow) unless incomplete || legacy
        return allow(before_allow) if maintenance_route?(argv, route)
        return allow(before_allow) if route == "setup" && !incomplete && !legacy
        action = incomplete ? "hive runtime status" : "hive migrate --all --yes"
        raise MigrationRequired.new(
          "Hive runtime activation is incomplete; ordinary commands are fenced",
          code: :fleet_cutover_required, action: action,
          details: { argv: Array(argv).map(&:to_s) }
        )
      end

      def active?(state_home)
        active_status?(runtime_status(state_home))
      rescue RuntimeControlPlane::Error, KeyError
        false
      end

      def runtime_status(state_home)
        database = Database.new(path: Hive::Paths.runtime_control_plane_path(state_home))
        Cutover.inspect_status(state_home: state_home, database: database)
      ensure
        database&.disconnect
      end

      def wait_for_active!(state_home, sleeper:, monotonic_clock:)
        deadline = monotonic_clock.call + SERVICE_ACTIVATION_WAIT_SEC
        until active?(state_home)
          if monotonic_clock.call >= deadline
            raise MigrationRequired.new(
              "Hive service activation is waiting for cutover completion",
              code: :fleet_cutover_required, action: "hive runtime status"
            )
          end
          sleeper.call(0.05)
        end
      end

      def active_status?(status) = status.fetch("phase") == "active" && status.dig("database", "status") == "ok"

      def managed_service_route?(argv)
        argv == %w[daemon start] || argv == %w[bot start --foreground] || argv == [ "web" ]
      end

      def maintenance_route?(argv, route = command(argv))
        route == "doctor" || (route == "migrate" && argv.include?("--all")) ||
          (route == "runtime" && %w[status resume].include?(subcommand(argv, route)))
      end

      def legacy_present?(state_home, data_home, config_home)
        return true if GLOBAL_LEGACY_PATHS.any? { |path| entry?(File.join(state_home, path)) }
        return true if DATA_LEGACY_PATHS.any? { |path| entry?(File.join(data_home, path)) }
        registry_has_projects?(File.join(config_home, "config.yml"))
      end

      def registry_has_projects?(path)
        return false unless File.file?(path)

        document = YAML.safe_load_file(path, permitted_classes: [], aliases: false)
        !Array(document.is_a?(Hash) && document["registered_projects"]).empty?
      rescue Psych::Exception, SystemCallError
        true
      end

      def command(argv) = argv.find { |arg| !arg.start_with?("-") }

      def subcommand(argv, name)
        index = argv.index(name)
        argv.drop(index + 1).find { |arg| !arg.start_with?("-") } if index
      end

      def version_route?(argv) = argv == [ "--version" ] || argv == [ "-v" ]
      def cutover_present?(state_home) = entry?(File.join(state_home, ".runtime-cutover", "current"))
      def database_present?(state_home) = entry?(Hive::Paths.runtime_control_plane_path(state_home))
      def entry?(path) = File.exist?(path) || File.symlink?(path)

      def allow(callback) = callback&.call || true
    end
  end
end
