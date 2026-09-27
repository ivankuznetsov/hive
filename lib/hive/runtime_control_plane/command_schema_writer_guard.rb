# frozen_string_literal: true

require "hive/config"
require "hive/invoked_binary"
require "hive/paths"
require "hive/pid_file"

module Hive
  module RuntimeControlPlane
    module CommandSchemaWriterGuard
      module_function

      def verify!(state_home: Hive::Paths.state_home,
                  registered_projects: Hive::Config.registered_projects,
                  alive: Hive::PidFile.method(:alive?),
                  ownership: Hive::PidFile.method(:ownership),
                  web_running: method(:managed_web_running?))
        roots = [ state_home ] + Array(registered_projects).filter_map do |entry|
          entry.is_a?(Hash) && (entry["hive_state_path"] ||
            (entry["path"] && File.join(entry["path"], ".hive-state")))
        end
        pid_paths = roots.flat_map do |root|
          %w[.daemon.pid .babysitter.pid .web.pid].map { |name| File.join(root, name) }
        end.uniq
        pid_paths.each { |path| verify_pid_file!(path, alive: alive, ownership: ownership) }
        if web_running.call
          raise Hive::ConfigError,
                "command receipt installation requires the managed Hive web service to be stopped"
        end
        true
      end

      def verify_pid_file!(path, alive:, ownership:)
        return true unless File.exist?(path) || File.symlink?(path)
        payload = Hive::PidFile.parse_payload(File.read(path))
        pid = payload && payload["pid"]
        unless pid.is_a?(Integer) && pid.positive?
          raise Hive::ConfigError,
                "cannot verify command-schema writer liveness from #{path}; repair the PID file and retry"
        end
        classification = Hive::PidFile.death_classification(
          pid: pid, recorded_start_time: payload["process_start_time"],
          alive: alive, ownership: ownership
        )
        return true if %i[dead reused].include?(classification)

        raise Hive::ConfigError,
              "command receipt installation requires stopped writers; #{path} identifies a " \
              "#{classification == :live ? 'live' : 'liveness-unverifiable'} process"
      rescue Hive::Error
        raise
      rescue SystemCallError, IOError => error
        raise Hive::ConfigError,
              "cannot verify command-schema writer liveness from #{path}: #{error.message}"
      end

      def managed_web_running?
        require "hive/commands/web/service_installer"
        installer = Hive::Commands::Web::ServiceInstaller.new(
          binary_path: Hive::InvokedBinary.path
        )
        state = if installer.respond_to?(:service_lifecycle_state)
          installer.service_lifecycle_state
        else
          installer.service_state
        end
        state["service_running"] == true
      rescue Hive::Error, SystemCallError, IOError => error
        raise Hive::ConfigError,
              "cannot verify managed Hive web writer liveness: #{error.message}"
      end
    end
  end
end
