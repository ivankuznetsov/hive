# frozen_string_literal: true

require "hive/remote/contract"

require "hive/remote/client"
require "hive/connection_contexts"
require "hive/cli_argv_policy"
require "securerandom"

module Hive
  module Remote
    # Runs before local runtime activation and project discovery. Its option
    # parser never includes rejected argument values in an error diagnostic.
    class Dispatcher
      NEW_VALUES = %w[--base --depends-on --workflow --idempotency-key].freeze
      MAX_ANSWER_BYTES = 64 * 1024

      class ReportedError < Hive::Error
        def initialize(error)
          @exit_code = error.exit_code
          super(error.message)
        end

        def exit_code = @exit_code
      end

      class Arguments
        attr_reader :positionals, :options

        def initialize(argv, command:, values: [], switches: [], repeatable: [])
          @positionals, @options = [], {}
          command_index = argv.index { |arg| !arg.start_with?("-") }
          raise Hive::UsageError, "missing command" unless command_index

          flags = argv.take(command_index) + argv.drop(command_index + 1)
          literal = false
          index = 0
          while index < flags.length
            arg = flags[index]
            if literal
              @positionals << arg
            elsif arg == "--"
              literal = true
            elsif Hive::CliJsonOptions::BOOLEAN_OPTIONS.include?(arg)
              @options["json"] = Hive::CliJsonOptions::TRUE_OPTIONS.include?(arg)
            elsif arg.start_with?("--")
              name, value = arg.delete_prefix("--").split("=", 2)
              if values.include?(name)
                if value.nil?
                  index += 1
                  value = flags[index]
                  raise Hive::UsageError, "#{command} requires a value for --#{name}" if !value || value.start_with?("-")
                end
                if repeatable.include?(name)
                  (@options[name] ||= []) << value
                else
                  @options[name] = value
                end
              elsif switches.include?(name) && (value.nil? || %w[true TRUE t T false FALSE f F].include?(value))
                @options[name] = value.nil? || %w[true TRUE t T].include?(value)
              elsif name.start_with?("no-", "skip-") && switches.include?(name.sub(/\A(?:no|skip)-/, "")) && value.nil?
                @options[name.sub(/\A(?:no|skip)-/, "")] = false
              else
                raise Hive::UsageError, "unsupported option for #{command}; use hive help #{command}"
              end
            elsif arg.start_with?("-")
              raise Hive::UsageError, "unsupported option for #{command}; use hive help #{command}"
            else
              @positionals << arg
            end
            index += 1
          end
        end

        def arity!(minimum, maximum = minimum, usage:)
          raise Hive::UsageError, "expected #{usage}" unless @positionals.length.between?(minimum, maximum)
        end

        def [](key) = @options[key]
        def json? = @options["json"] == true
      end

      def self.contexts
        Hive::ConnectionContexts.new(verifier: ->(context, bearer) { Client.new(context: context, bearer: bearer).context })
      end

      def initialize(contexts: self.class.contexts, stdout: $stdout, stderr: $stderr, stdin: $stdin)
        @contexts, @stdout, @stderr, @stdin = contexts, stdout, stderr, stdin
      end

      def call(invocation)
        @command_reports_errors = false
        return context_command(invocation) if invocation.command == "context"
        return client_help(invocation) if client_help?(invocation)

        transport = Client.new(context: invocation.context, bearer: @contexts.credential(invocation.context))
        case invocation.command
        when "status" then status(invocation, transport)
        when "task" then task(invocation, transport)
        when "new" then create(invocation, transport)
        when "act" then act(invocation, transport)
        when "answer" then answer(invocation, transport)
        when "approve" then approve(invocation, transport)
        when "operation" then operation(invocation, transport)
        end
      rescue Hive::Error
        raise
      rescue StandardError
        raise Client::Failure.new("remote response could not be used", code: "protocol")
      end

      def client_help?(invocation)
        return false unless invocation.command == "help"

        words = invocation.argv.reject { |arg| Hive::CliJsonOptions::BOOLEAN_OPTIONS.include?(arg) }
        %w[context token operation].include?(words[1])
      end

      # Validate token grammar before Thor can echo an accidental literal
      # bearer in its arity/unknown-option banner. Administration still runs
      # through the normal local installation lifecycle.
      def validate_local!(invocation)
        if invocation.command == "token"
          if invocation.argv.any? { |arg| arg.split("=", 2).last.match?(/\A[0-9a-f]{24}\.[0-9a-f]{64}\z/i) }
            raise Hive::UsageError, "bearer credentials must be supplied through context add --token-stdin"
          end
          args = arguments(invocation, values: %w[scopes projects name expires-at], switches: [ "all-projects" ])
          args.arity!(0, 2, usage: "token create, token list, or token revoke ID")
          action = args.positionals.first || "list"
          valid = %w[create list revoke].include?(action) &&
            (action == "revoke" ? args.positionals.length == 2 : args.positionals.length <= 1)
          raise Hive::UsageError, "expected token create, token list, or token revoke ID" unless valid
          if action == "revoke" && !args.positionals.last.match?(/\A[0-9a-f]{24}\z/i)
            raise Hive::UsageError, "token revoke requires a public token ID"
          end
          if action != "create" && (args.options.keys - [ "json" ]).any?
            raise Hive::UsageError, "token creation options require token create"
          end
        elsif invocation.command == "operation"
          raise Hive::UsageError, "operation lookup requires --context <remote>; use hive receipt for local commands"
        elsif invocation.command == "task" && remote_selector?(invocation.argv)
          raise Hive::UsageError, "these task selectors require --context <remote>; use the local hive task TARGET --json artifact panel"
        elsif invocation.command == "approve" && Hive::CliArgvPolicy.option_argv(invocation.argv).any? { |arg| arg == "--generation" || arg.start_with?("--generation=") }
          raise Hive::UsageError, "--generation requires --context <remote>; local approvals use --from"
        end
      end

      def report_error(error, invocation)
        return if error.is_a?(ReportedError)
        return unless Hive::CliArgvPolicy.json_requested?(invocation.argv)

        unless @command_reports_errors
          document = if %w[context token operation].include?(invocation.command)
            schema = "hive-#{invocation.command}"
            kind = error.is_a?(Hive::ConfigError) || error.is_a?(Client::UnsupportedVersion) ? "config" : error.is_a?(Hive::UsageError) ? "usage" : "remote"
            kind = "internal" if invocation.command == "context" && kind == "remote"
            Hive::Schemas::ErrorEnvelope.build(schema: schema, error: error, error_kind: kind)
          else
            code = error.respond_to?(:code) ? error.code.to_s : error.is_a?(Hive::UsageError) ? "usage" : "unavailable"
            detail = { "code" => code, "message" => error.message }
            if error.is_a?(Client::UnknownSubmission)
              detail.merge!("idempotency_key" => error.key, "target" => error.target)
            end
            { "schema" => "hive-remote", "schema_version" => Hive::Schemas::SCHEMA_VERSIONS.fetch("hive-remote"),
              "ok" => false, "instance_id" => invocation.context["instance_id"], "error" => detail }
          end
          @stdout.puts(JSON.generate(document))
        end
        raise ReportedError.new(error)
      end

      private

      def arguments(invocation, values: [], switches: [], repeatable: [])
        argv = invocation.argv.dup
        command_index = argv.index { |arg| !arg.start_with?("-") }
        argv[command_index] = invocation.command
        text_start = Hive::CliArgvPolicy.new_text_start_index(argv, value_options: NEW_VALUES)
        Hive::CliArgvPolicy.reject_unsupported_json_assignments(argv, before_index: text_start)
        argv = Hive::CliArgvPolicy.lift_new_options(argv, value_options: NEW_VALUES)
        Arguments.new(argv, command: invocation.command, values: values, switches: switches, repeatable: repeatable)
      rescue Thor::Error
        raise Hive::UsageError, "invalid JSON option; use --json or --no-json"
      end

      def context_command(invocation)
        args = arguments(invocation, values: [ "url" ], switches: [ "token-stdin" ])
        args.arity!(0, 2, usage: "context add NAME, list, use NAME, or show [NAME]")
        require "hive/commands/context"
        @command_reports_errors = true
        Hive::Commands::Context.new(args.positionals[0] || "list", args.positionals[1],
          url: args["url"], token_stdin: args["token-stdin"], json: args.json?,
          contexts: @contexts, stdin: @stdin, stdout: @stdout).call
      end

      def client_help(invocation)
        args = arguments(invocation)
        args.arity!(1, usage: "help context, token, or operation")
        require "hive/cli"
        require "hive/remote/command_policy"
        Hive::Remote::CommandPolicy.with_invocation(invocation) do
          Hive::CLI.start(Hive::CliArgvPolicy.normalize_leading_json_options(invocation.argv))
        end
      end

      def status(invocation, transport)
        args = arguments(invocation, values: %w[project cursor], switches: [ "operational" ])
        args.arity!(0, usage: "status [--project PROJECT]")
        if args["operational"]
          raise Hive::UsageError, "remote status does not support --operational; use status --json or --context local"
        end
        project_name!(args["project"]) if args["project"]
        query = args.options.slice("project", "cursor")
        opaque!(args["cursor"]) if args["cursor"]
        document = transport.get("/status", query: query)
        emit(document, args)
      end

      def task(invocation, transport)
        args = arguments(invocation, values: %w[project artifact output], switches: %w[log diff artifacts])
        args.arity!(1, usage: "task TARGET --project PROJECT")
        project, target = target!(args.positionals.first, args["project"])
        selectors = %w[log diff artifacts artifact].select { |name| args[name] }
        raise Hive::UsageError, "choose only one task content selector" if selectors.length > 1
        raise Hive::UsageError, "--output requires a task content selector" if args["output"] && selectors.empty?

        selector = selectors.first
        suffix = case selector
        when "log" then "/logs"
        when "diff" then "/diff"
        when "artifacts" then "/artifacts"
        when "artifact" then "/artifacts/#{opaque!(args['artifact'])}"
        else ""
        end
        document = transport.get("#{task_path(project, target)}#{suffix}")
        emit(document, args, selector: selector)
      end

      def create(invocation, transport)
        args = arguments(invocation, values: %w[base depends-on workflow idempotency-key], repeatable: [ "depends-on" ])
        args.arity!(2, 1_000_000, usage: "new PROJECT TEXT")
        project = project_name!(args.positionals.first)
        text = args.positionals.drop(1).join(" ")
        raise Hive::UsageError, "new requires non-blank task text" if text.strip.empty?

        payload = { "text" => text }
        %w[base workflow].each { |field| payload[field] = args[field] if args[field] }
        if args["depends-on"]
          dependencies = args["depends-on"]
          dependencies.each { |dependency| target!(dependency, project, cross_project: true) }
          payload["depends_on"] = dependencies.length == 1 ? dependencies.first : dependencies
        end
        mutate(transport, "/projects/#{escape(project)}/tasks", payload, args, target: "#{project}:new")
      end

      def act(invocation, transport)
        args = arguments(invocation, values: %w[project observation idempotency-key])
        args.arity!(2, usage: "act ACTION_ID TARGET --observation TOKEN")
        project, target = target!(args.positionals[1], args["project"])
        raise Hive::UsageError, "act requires --observation from fresh remote status or task details" unless args["observation"]

        payload = { "action_id" => args.positionals.first, "observation" => args["observation"] }
        mutate(transport, "#{task_path(project, target)}/actions", payload, args, target: "#{project}:#{target}")
      end

      def answer(invocation, transport)
        args = arguments(invocation, values: %w[project binding idempotency-key])
        args.arity!(1, usage: "answer TARGET --project PROJECT")
        project, target = target!(args.positionals.first, args["project"])
        path = "#{task_path(project, target)}/questions"
        return emit(transport.get(path), args) unless args["binding"]

        answer = @stdin.read(MAX_ANSWER_BYTES + 1).to_s.dup.force_encoding(Encoding::UTF_8)
        unless answer.bytesize <= MAX_ANSWER_BYTES && answer.valid_encoding? && !answer.strip.empty?
          raise Hive::UsageError, "answer requires non-blank UTF-8 stdin of at most 64 KiB"
        end
        payload = { "handle" => args["binding"], "answer" => answer }
        mutate(transport, "#{task_path(project, target)}/answers", payload, args, target: "#{project}:#{target}")
      end

      def approve(invocation, transport)
        args = arguments(invocation, values: %w[project from generation idempotency-key])
        args.arity!(1, usage: "approve TARGET --project PROJECT --from STAGE [--generation GENERATION]")
        project, target = target!(args.positionals.first, args["project"])
        stage, generation = args["from"], args["generation"]
        if !stage || !generation
          metadata = transport.context
          unless metadata.dig("token", "scopes").include?("read")
            raise Hive::UsageError, "approval without read scope requires --from STAGE and --generation GENERATION"
          end
          data = transport.get(task_path(project, target)).fetch("data")
          stage ||= data.dig("task", "stage")
          generation ||= data["approval_generation"]
        end
        unless stage.is_a?(String) && stage.match?(Contract::STAGE) &&
            generation.is_a?(String) && generation.match?(Contract::GENERATION)
          raise Hive::UsageError, "approval requires a full --from stage and its fresh --generation"
        end
        mutate(transport, "#{task_path(project, target)}/approvals", { "stage" => stage, "generation" => generation },
          args, target: "#{project}:#{target}")
      end

      def operation(invocation, transport)
        args = arguments(invocation, values: [ "project" ])
        args.arity!(1, usage: "operation ID --project PROJECT")
        project_name!(args["project"])
        require "hive/commands/operation"
        @command_reports_errors = true
        Hive::Commands::Operation.new(args.positionals.first, project: args["project"], json: args.json?,
          client: transport, stdout: @stdout).call
      end

      def mutate(transport, path, payload, args, target:)
        key = args["idempotency-key"] || SecureRandom.hex(32)
        emit(transport.mutate(path, payload, key: key, target: target, stderr: @stderr), args)
      end

      def emit(document, args, selector: nil)
        data = document.fetch("data")
        content = case selector
        when "log", "artifact" then data["content"]
        when "diff" then data.fetch("sections", {}).values.compact.join("\n")
        when "artifacts" then JSON.pretty_generate(data)
        end
        if args["output"]
          raise Client::Failure.new("requested remote content is unavailable") unless content.is_a?(String)

          begin
            File.binwrite(args["output"], content)
          rescue SystemCallError, IOError
            raise Hive::UsageError, "could not write the explicit output destination"
          end
        end
        if args.json?
          @stdout.puts(JSON.generate(document))
        elsif args["output"]
          @stdout.puts("Saved requested remote content")
        elsif selector && content.is_a?(String)
          @stdout.write(content)
          @stdout.puts unless content.end_with?("\n")
        else
          @stdout.puts(JSON.pretty_generate(data))
        end
        document
      end

      def target!(value, project, cross_project: false)
        parts = value.to_s.split(":", -1)
        if parts.length == 2
          explicit, task = parts
          if project && explicit != project && !cross_project
            raise Hive::UsageError, "task target and --project must name the same project"
          end
          project = explicit
        elsif parts.length == 1
          task = parts.first
        else
          raise Hive::UsageError, "remote targets require an exact PROJECT:TASK or TASK with --project"
        end
        project_name!(project)
        unless task&.match?(Contract::TASK_ID)
          raise Hive::UsageError, "remote tasks require exact IDs or slugs, never filesystem paths"
        end
        [ project, task ]
      end

      def project_name!(value)
        unless value.is_a?(String) && value.match?(Contract::PROJECT_NAME) && !%w[. ..].include?(value)
          raise Hive::UsageError, "remote commands require an explicit registered project name"
        end
        value
      end

      def opaque!(value)
        unless value.is_a?(String) && value.match?(/\A[A-Za-z0-9_.-]{1,4096}\z/) && !%w[. ..].include?(value)
          raise Hive::UsageError, "artifact selection requires an opaque ID from the remote manifest"
        end
        escape(value)
      end

      def task_path(project, task) = "/projects/#{escape(project)}/tasks/#{escape(task)}"
      def escape(value) = URI.encode_www_form_component(value)

      def remote_selector?(argv)
        Hive::CliArgvPolicy.option_argv(argv).any? { |arg| %w[--diff --artifacts --artifact --output].any? { |flag| arg == flag || arg.start_with?("#{flag}=") } }
      end
    end
  end
end
