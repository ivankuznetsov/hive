# frozen_string_literal: true

require "hive/cli_json_options"
require "thor"

module Hive
  # Pure wrapper-level argv transformations shared by the Hive executables.
  # Callers keep command-specific dispatch and error-envelope policy; this
  # module owns common byte validation, JSON grammar, option placement, and
  # command-local help rewriting.
  module CliArgvPolicy
    module_function

    def option_argv(argv)
      Hive::CliJsonOptions.option_argv(argv)
    end

    def json_requested?(argv)
      Hive::CliJsonOptions.requested?(argv)
    end

    def validate_encoding(argv)
      idx = argv.index { |arg| !arg.dup.force_encoding(Encoding::UTF_8).valid_encoding? }
      return argv.dup unless idx

      raise Thor::MalformattedArgumentError, "invalid byte sequence in argument #{idx + 1}"
    end

    def reject_unsupported_json_assignments(argv, before_index: nil)
      arg = Hive::CliJsonOptions.unsupported_assignment(argv, before_index: before_index)
      return argv.dup unless arg

      value = arg.split("=", 2).last
      raise Thor::MalformattedArgumentError, "invalid boolean value for --json: #{value.inspect}"
    end

    def normalize_leading_json_options(argv, commands: nil, top_level_flags: [], help_flags: [])
      normalized = argv.dup
      leading = []
      leading << normalized.shift while Hive::CliJsonOptions::BOOLEAN_OPTIONS.include?(normalized.first)
      return normalized if leading.empty?

      if top_level_flags.include?(normalized.first)
        return normalized if normalized.length == 1
        return normalized if help_flags.include?(normalized.first) && Array(commands).include?(normalized[1])

        return leading + normalized
      end

      command_index = if commands
        normalized.index { |arg| commands.include?(arg) }
      else
        option_argv(normalized).index { |arg| !arg.start_with?("-") }
      end
      return leading + normalized unless command_index

      normalized.insert(command_index + 1, *leading)
    end

    def rewrite_help(argv, text_start_index: nil, known_commands: nil, fallback_command: nil)
      normalized = argv.dup
      options = option_argv(normalized)
      command_index = options.index { |arg| !arg.start_with?("-") }
      return normalized unless command_index

      scan_limit = [ options.length, text_start_index ].compact.min
      help_index = (command_index + 1...scan_limit).find do |idx|
        normalized[idx] == "--help" || normalized[idx] == "-h"
      end
      return normalized unless help_index

      command = normalized[command_index]
      target = if known_commands.nil? || known_commands.include?(command)
        command
      else
        fallback_command
      end
      return normalized unless target

      normalized[0...command_index] + [ "help", target ]
    end

    def new_text_start_index(argv, value_options:)
      options = option_argv(argv)
      command_index = options.index { |arg| !arg.start_with?("-") }
      return nil unless command_index && argv[command_index] == "new"

      index = command_index + 1
      project_index = nil
      while index < options.length
        arg = options[index]
        if Hive::CliJsonOptions::BOOLEAN_OPTIONS.include?(arg)
          index += 1
          next
        end
        if value_options.include?(arg)
          index += 2
          next
        end
        if value_assignment?(arg, value_options)
          index += 1
          next
        end
        unless arg.start_with?("-")
          project_index = index
          break
        end

        index += 1
      end
      project_index && project_index + 1
    end

    def lift_new_options(argv, value_options:)
      normalized = argv.dup
      command_index = option_argv(normalized).index { |arg| !arg.start_with?("-") }
      return normalized unless command_index && normalized[command_index] == "new"

      lifted = []
      rest = []
      protected_tail = false
      index = command_index + 1
      while index < normalized.length
        arg = normalized[index]
        if protected_tail
          rest << arg
        elsif arg == "--"
          protected_tail = true
        elsif Hive::CliJsonOptions::BOOLEAN_OPTIONS.include?(arg)
          lifted << arg
        elsif value_options.include?(arg)
          value = normalized[index + 1]
          if value && !value.start_with?("-")
            lifted << arg << value
            index += 1
          else
            rest << arg
          end
        elsif value_assignment?(arg, value_options)
          lifted << arg
        else
          rest << arg
        end
        index += 1
      end

      project = rest.shift
      return normalized unless project

      tail = rest.empty? ? [] : [ "--", *rest ]
      normalized[0...command_index] + [ "new", *lifted, project, *tail ]
    end

    def value_assignment?(arg, value_options)
      value_options.any? { |name| arg.start_with?("#{name}=") }
    end
    private_class_method :value_assignment?
  end
end
