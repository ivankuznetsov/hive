require "hive/runtime_control_plane/installation"
require "hive/runtime_control_plane/operational_inspection"
require "hive/cli_json_options"

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

      # Conservative recognition of the bounded running-status surface. Unknown
      # options stay on normal dispatch so startup fallback cannot hide usage
      # errors or grant observation behavior to a write-capable diagnosis.
      def default_status_route?(argv)
        words = Array(argv).map(&:to_s)
        return false unless words.all? { |word| word.dup.force_encoding(Encoding::UTF_8).valid_encoding? }

        route_index = words.index("status")
        return false unless route_index && command(words) == "status"
        return false unless words.first(route_index).all? { |word| Hive::CliJsonOptions::BOOLEAN_OPTIONS.include?(word) }

        switches = words.drop(route_index + 1).map { |word| word.tr("_", "-") }
        names = %w[write force operational internal-task-graph]
        return false if names.any? { |name| OperationalInspection.boolean_option_value(switches, name) == true }

        index = 0
        while index < switches.length
          word = switches[index]
          if %w[--project --stage].include?(word)
            index += 1
            return false unless switches[index] && !switches[index].start_with?("-")
          elsif word.match?(/\A--(?:project|stage)=.+\z/) || Hive::CliJsonOptions::BOOLEAN_OPTIONS.include?(word)
            # Existing default-status options.
          elsif names.any? { |name| word.match?(/\A--(?:(?:no-|skip-)?#{name}|#{name}=(?:true|false|t|f))\z/i) }
            index += 1 if switches[index + 1]&.match?(/\A(?:true|false|t|f)\z/i)
          else
            return false
          end
          index += 1
        end
        true
      end

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
        return [ nil, "status", "projects", "payloads" ].include?(subcommand_after(words, route)) if route == "runtime"

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
