require "hive/runtime_control_plane/installation"

module Hive
  module RuntimeControlPlane
    # Read-only process-start validation, before scheduler reconciliation.
    module ActivationGate
      module_function

      def check!(argv: ARGV, state_home: Hive::Paths.state_home, before_allow: nil)
        argv = Array(argv).map(&:to_s)
        route = command(argv)
        maintenance = %w[setup doctor version].include?(route) ||
          argv == [ "--version" ] || argv == [ "-v" ] ||
          (route == "runtime" && [ nil, "status" ].include?(command(argv.drop(argv.index(route) + 1))))
        runtime_status(state_home) unless maintenance
        before_allow&.call || true
      end

      def active?(state_home)
        runtime_status(state_home).fetch("phase") == "active"
      rescue RuntimeControlPlane::Error, KeyError
        false
      end

      def command(argv) = argv.find { |arg| !arg.start_with?("-") }

      def runtime_status(state_home) = Installation.status(state_home: state_home)
    end
  end
end
