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
          strict_no_write_route?(argv)
        runtime_status(state_home) unless maintenance
        before_allow&.call || true
      end

      def active?(state_home)
        runtime_status(state_home).fetch("phase") == "active"
      rescue RuntimeControlPlane::Error, KeyError
        false
      end

      def command(argv) = argv.find { |arg| !arg.start_with?("-") }

      def subcommand_after(argv, route, value_options: [])
        skip_value = false
        argv.drop(argv.index(route) + 1).each do |argument|
          if skip_value
            skip_value = false
          elsif value_options.include?(argument)
            skip_value = true
          elsif value_options.any? { |option| argument.start_with?("#{option}=") }
            next
          elsif !argument.start_with?("-")
            return argument
          end
        end
        nil
      end

      # These routes are observations (or lifecycle controls that own their
      # own fenced writes). They must be recognized before startup command
      # registration and scheduler reconciliation so their established
      # no-write contract is not defeated by process bootstrap.
      def strict_no_write_route?(argv)
        words = Array(argv).map(&:to_s)
        route = command(words)
        if route == "daemon"
          return %w[status quiesce resume].include?(
            subcommand_after(words, route, value_options: %w[--timeout])
          )
        end
        return [ nil, "status" ].include?(subcommand_after(words, route)) if route == "runtime"

        if route == "init"
          return words.drop(words.index(route) + 1).any? do |argument|
            argument == "--preview" || argument.match?(/\A--preview=true\z/i)
          end
        end
        return false unless route == "workflow"

        workflow_subcommands = %w[new validate commit install list update remove publish]
        workflow_subcommand = words.drop(words.index(route) + 1).find do |argument|
          workflow_subcommands.include?(argument)
        end
        workflow_subcommand == "validate"
      end

      def runtime_status(state_home) = Installation.status(state_home: state_home)
    end
  end
end
