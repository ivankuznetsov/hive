# frozen_string_literal: true

require "hive/connection_contexts"
require "hive/cli_argv_policy"

module Hive
  module Remote
    # This vocabulary is deliberately independent of Thor and the daemon's
    # broader verb allowlist. It runs before runtime registration or discovery.
    module CommandPolicy
      ALIASES = {
        "new_task" => "new", "run_task" => "run", "generate_name" => "generate-name",
        "rebase_status" => "rebase-status", "publication_reconcile" => "publication-reconcile",
        "plan_review" => "plan-review", "plan_review_run" => "plan-review-run",
        "open_pr" => "open-pr", "pr" => "open-pr", "accept_finding" => "accept-finding",
        "reject_finding" => "reject-finding", "setup_agents" => "setup-agents",
        "refactor_patrol" => "refactor-patrol", "refactor_patrol_scheduled" => "refactor-patrol-scheduled",
        "refactor_patrol_classify" => "refactor-patrol-classify", "answer_digest" => "answer-digest",
        "--version" => "version", "-v" => "version", "--help" => "help", "-h" => "help",
        "-?" => "help", "-D" => "help", "-t" => "tree", "--tree" => "tree"
      }.freeze
      CONTEXT_MANAGEMENT = %w[context help tree version].freeze
      SUPPORTED_REMOTE = %w[status task new act answer approve operation].freeze
      LOCAL_ONLY = %w[
        init forget prune receipt doctor setup-agents setup update connect disconnect mcp uninstall
        runtime wiki workflow module bench generate-name run rebase-status publication-reconcile
        worktree evidence brainstorm plan plan-review plan-review-run develop open-pr review artifacts
        finalize archive drop patrol refactor-patrol refactor-patrol-scheduled refactor-patrol-classify
        __patrol_fix_semantic_decision answer-digest digest watch decide findings accept-finding
        reject-finding markers babysit daemon bot pairing web tui metrics token __attempt-supervise __module-hook
      ].freeze
      READ_ONLY = %w[help tree version doctor rebase-status findings task watch metrics operation].freeze
      Invocation = Struct.new(:argv, :context, :command, :result, :handled, keyword_init: true) do
        def handled? = !!handled
      end

      module_function

      def current_invocation = Thread.current[:hive_connection_invocation]

      def with_invocation(invocation)
        previous = current_invocation
        Thread.current[:hive_connection_invocation] = invocation
        yield
      ensure
        Thread.current[:hive_connection_invocation] = previous
      end

      def classify(command)
        name = canonical(command)
        return :context_management if CONTEXT_MANAGEMENT.include?(name)
        return :supported_remote if SUPPORTED_REMOTE.include?(name)
        return :local_only if LOCAL_ONLY.include?(name)

        :unsupported
      end

      def canonical(command) = ALIASES.fetch(command.to_s, command.to_s)

      def preflight!(argv, contexts: Hive::ConnectionContexts.new, dispatcher: nil, stderr: $stderr)
        clean_argv, selected = Hive::CliArgvPolicy.extract_context(argv)
        text_start = Hive::CliArgvPolicy.new_text_start_index(
          clean_argv, value_options: %w[--base --depends-on --workflow --idempotency-key --context]
        )
        clean_argv = Hive::CliArgvPolicy.rewrite_help(clean_argv, text_start_index: text_start)
        command = canonical(Hive::CliArgvPolicy.command_name(clean_argv) || "help")
        context = contexts.resolve(name: selected)
        invocation = Invocation.new(
          argv: clean_argv.map { |arg| arg.dup.freeze }.freeze,
          context: context.transform_values { |value| value.is_a?(String) ? value.dup.freeze : value }.freeze,
          command: command
        )
        category = classify(command)
        dispatcher.validate_local!(invocation) if context.fetch("type") == "local" && dispatcher.respond_to?(:validate_local!)
        if context.fetch("type") == "remote" && category != :context_management
          unless category == :supported_remote
            raise Hive::UsageError, "#{command} requires a local context; specify --context local"
          end
          unless dispatcher
            raise Hive::UsageError, "remote transport is unavailable; specify --context local"
          end
          invocation.result = dispatcher.call(invocation)
          invocation.handled = true
        elsif dispatcher && (command == "context" || dispatcher.respond_to?(:client_help?) && dispatcher.client_help?(invocation))
          if mutation?(command, clean_argv)
            stderr.puts("hive: context=local installation=local authority=unrestricted-local-operator target=local-client-configuration")
            stderr.flush
          end
          invocation.result = dispatcher.call(invocation)
          invocation.handled = true
        elsif mutation?(command, clean_argv)
          target = target_for(command, clean_argv)
          stderr.puts("hive: context=local installation=local authority=unrestricted-local-operator target=#{target}")
          stderr.flush
        end
        invocation
      rescue Hive::Error => error
        dispatcher.report_error(error, invocation) if invocation && dispatcher.respond_to?(:report_error)
        raise
      end

      def mutation?(command, argv)
        return false if READ_ONLY.include?(command) || classify(command) == :unsupported

        options = Hive::CliArgvPolicy.option_argv(argv)
        case command
        when "context" then %w[add use].include?(positional_arguments(argv).first)
        when "token" then %w[create revoke].include?(positional_arguments(argv).first)
        when "runtime" then ![ nil, "status", "projects", "payloads" ].include?(positional_arguments(argv).first)
        when "status" then options.include?("--write")
        when "answer" then options.include?("--binding") || options.any? { |arg| arg.start_with?("--binding=") }
        when "archive" then positional_arguments(argv).any?
        when "patrol", "refactor-patrol" then !options.include?("--list") && !options.include?("--show")
        when "digest" then %w[prune repair resend send].include?(positional_arguments(argv).first)
        else true
        end
      end

      def target_for(command, argv)
        return "local-client-configuration" if command == "context"
        return "local-server-token-registry" if command == "token"

        project_index = argv.index("--project")
        project = project_index && argv[project_index + 1]
        project ||= argv.find { |arg| arg.start_with?("--project=") }&.split("=", 2)&.last
        arguments = positional_arguments(argv)
        target = command == "act" ? arguments[1] : arguments[0]
        target = [ project, target ].compact.uniq.join(":") unless project && target&.start_with?("#{project}:")
        target.to_s.then do |text|
          text.empty? ? "local-installation" : text.gsub(/[[:cntrl:]]/, "?")[0, 200]
        end
      end

      def positional_arguments(argv)
        arguments = []
        skip = false
        command_index = argv.index { |arg| !arg.start_with?("-") } || 0
        argv.drop(command_index + 1).each do |arg|
          break if arg == "--"
          if skip
            skip = false
          elsif arg.start_with?("--")
            skip = %w[--project --stage --from --to --idempotency-key --workflow --base --depends-on --observation --binding --generation].include?(arg)
          elsif !arg.start_with?("-")
            arguments << arg
          end
        end
        arguments
      end
      private_class_method :positional_arguments
    end
  end
end
