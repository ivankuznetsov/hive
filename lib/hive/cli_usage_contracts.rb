# frozen_string_literal: true

require "json"
require "hive"
require "hive/schemas"

module Hive
  # Pre-dispatch JSON usage-error contracts for the Hive CLI.
  #
  # This module is a generic resolution protocol, not a contract owner. Each
  # command boundary (lib/hive/commands/<command>.rb) declares the JSON
  # envelope its failures ride when Thor rejects argv before the command runs,
  # via {declare}: single-shape commands pass a contract hash, variant-aware
  # commands pass a resolver block, and commands with custom payload
  # construction (the refactor-patrol reporter, the native web/setup context,
  # workflow-validate diagnostics) own that payload lambda in their boundary
  # file too. Launchers stay generic: they ask for the argv's contract and
  # render the payload the boundary declares.
  module CliUsageContracts
    # Boundary files whose require path does not follow the
    # `hive/commands/<command.tr("-", "_")>` convention: both finding toggles
    # share one boundary file, and every workflow stage verb (plus its `pr`
    # alias) is owned by the stage-action boundary.
    BOUNDARY_REQUIRE_PATHS = {
      "accept-finding" => "finding_toggle",
      "reject-finding" => "finding_toggle",
      "pr" => "stage_action",
      "brainstorm" => "stage_action",
      "plan" => "stage_action",
      "develop" => "stage_action",
      "open-pr" => "stage_action",
      "review" => "stage_action",
      "artifacts" => "stage_action",
      "finalize" => "stage_action",
      "archive" => "stage_action"
    }.freeze

    @contracts = {}

    module_function

    # Declares `command`'s usage contract. Called from the command's own
    # boundary file. `contract` is a hash for single-shape commands;
    # variant-aware commands pass a resolver block
    # `(argv, command_index:, option_argv:)` that returns the contract hash,
    # or nil when the argv carries no JSON envelope.
    #
    # Contract hash keys: `:schema`, `:schema_version`, `:error_kind`,
    # `:extras`, `:omit_error_class`, and optionally `:payload` — a
    # `lambda(error, argv:)` that owns the entire payload construction for
    # the command (see {error_payload}).
    def declare(command, contract = nil, &resolver)
      raise ArgumentError, "declare requires a contract hash or a resolver block" if contract.nil? && resolver.nil?

      @contracts[command] = contract || resolver
      nil
    end

    def contract(argv, on_failure: nil)
      command_index = argv.index { |arg| !arg.b.start_with?("-") }
      return unless command_index

      command = argv.fetch(command_index)
      return unless command.valid_encoding?

      source = @contracts[command] || load_boundary_declaration!(command)
      return unless source
      return source if source.is_a?(Hash)

      source.call(argv, command_index: command_index, option_argv: option_region(argv, command_index))
    rescue StandardError, ScriptError => error
      # Contract resolution runs inside a launcher's pre-dispatch error
      # handler (bin/hive's `rescue Thor::Error` arm), so a boundary file
      # that fails to cold-load or a resolver that raises must never escape
      # that handler and replace the promised usage response with a crash.
      # Degrade to "no contract": the launcher then renders the plain human
      # usage error at the generic usage exit code. ScriptError is caught
      # alongside StandardError because LoadError (and SyntaxError) are its
      # subclasses, not StandardError's. Only the class enters the invocation's
      # diagnostic channel; messages, argv, and backtraces stay private.
      on_failure&.call(error.class)
      nil
    end

    # Renders the error payload for a resolved contract. A contract with a
    # `:payload` lambda owns its entire payload construction; everything else
    # rides the generic {generic_payload} envelope rendering.
    def error_payload(contract, error, argv: [])
      builder = contract[:payload]
      return builder.call(error, argv: argv) if builder

      generic_payload(contract, error)
    end

    # Generic envelope rendering shared by contracts that do not own their
    # payload: versioned schemas build a Hive::Schemas::ErrorEnvelope, all
    # other shapes fall back to the legacy unversioned document.
    def generic_payload(contract, error, extras: contract.fetch(:extras, {}))
      schema = contract[:schema]
      error_kind = contract.fetch(:error_kind)
      if schema && Hive::Schemas::SCHEMA_VERSIONS.key?(schema)
        payload = Hive::Schemas::ErrorEnvelope.build(
          schema: schema,
          error: error,
          error_kind: error_kind,
          extras: extras
        )
        payload.delete("error_class") if contract[:omit_error_class]
        return payload
      end

      payload = {}
      if schema
        payload["schema"] = schema
        payload["schema_version"] = contract.fetch(:schema_version, 1) unless contract[:schema_version] == false
      end

      payload.merge!(
        "ok" => false,
        "error_class" => error.class.name.split("::").last,
        "error_kind" => error_kind,
        "exit_code" => error.respond_to?(:exit_code) ? error.exit_code : Hive::ExitCodes::GENERIC,
        "message" => error.message
      ).merge(extras)
    end

    # The human-mode error class a launcher raises for a Thor rejection:
    # command-shaped `invalid_task_path` contracts keep the slug-flavored
    # error, everything else stays a generic UsageError.
    def usage_error(selected, message)
      klass = if selected&.fetch(:error_kind, nil) == "invalid_task_path"
        Hive::InvalidTaskPath
      else
        Hive::UsageError
      end
      klass.new(message)
    end

    # --- generic argv-region helpers used by boundary resolvers -------------

    def option_region(argv, command_index)
      argv.drop(command_index + 1).take_while { |arg| arg != "--" }
    end

    def subcommand(argv, command_index, value_options: [])
      skip_value = false
      options = true
      argv.drop(command_index + 1).each do |arg|
        if skip_value
          skip_value = false
          next
        end
        return unless arg.valid_encoding?

        if options && arg == "--"
          options = false
        elsif options && value_options.include?(arg)
          skip_value = true
        elsif options && arg.start_with?("-")
          next
        else
          return arg
        end
      end
      nil
    end

    def positionals(argv, command_index, value_options: [])
      positionals = []
      skip_value = false
      options = true
      argv.drop(command_index + 1).each do |arg|
        if skip_value
          skip_value = false
          next
        end
        next unless arg.valid_encoding?

        if options && arg == "--"
          options = false
        elsif options && value_options.include?(arg)
          skip_value = true
        elsif options && value_options.any? { |option| arg.start_with?("#{option}=") }
          next
        elsif options && arg.start_with?("-")
          next
        else
          positionals << arg
        end
      end
      positionals
    end

    # Loads the boundary file that owns `command` so its {declare} call runs.
    # The require path is a structural hint only — the contract itself is
    # declared by the boundary — and commands without a boundary file (for
    # example unknown commands) resolve to no contract. This lazy require can
    # raise (a missing dependency inside the boundary file, for example); the
    # caller {contract} is failure-safe and degrades such cold-load failures
    # to no contract instead of crashing the usage-error path.
    def load_boundary_declaration!(command)
      path = BOUNDARY_REQUIRE_PATHS.fetch(command) { command.tr("-", "_") }
      return unless path.match?(/\A[a-z0-9_]+\z/)
      return unless File.file?(File.expand_path("commands/#{path}.rb", __dir__))

      require "hive/commands/#{path}"
      @contracts[command]
    end
  end
end
