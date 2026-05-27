require "hive/stages/base"

module Hive
  module Bot
    class CodexConversation
      Result = Struct.new(:kind, :text, :draft, :reason, keyword_init: true)

      def initialize(config:, logger:, spawn_agent: nil)
        @config = config
        @logger = logger
        @spawn_agent = spawn_agent || method(:spawn_with_base)
      end

      def next_turn(task:, question:, history:, draft:, user_input:)
        prompt = render_prompt(question: question, history: history,
                               draft: draft, user_input: user_input)
        @logger.event(:codex_spawned, slug: task.slug, question_n: question.n)
        result = @spawn_agent.call(task: task, prompt: prompt, config: @config)

        return error(:timeout, task, question) if result[:timed_out] || result[:status] == :timeout
        unless result[:status] == :ok || result[:exit_code] == 0
          return error(result[:error_message] || "exit_code=#{result[:exit_code]}", task, question)
        end

        parsed = parse_response(result[:final_message].to_s)
        if parsed.kind == :error
          @logger.event(:codex_failed, slug: task.slug, question_n: question.n,
                                       reason: parsed.reason.to_s)
        else
          @logger.event(:codex_succeeded, slug: task.slug, question_n: question.n,
                                         kind: parsed.kind.to_s)
        end
        parsed
      end

      private

      def render_prompt(question:, history:, draft:, user_input:)
        tag = Hive::Stages::Base.user_supplied_tag
        bindings = Hive::Stages::Base::TemplateBindings.new(
          question: question,
          history: Array(history),
          draft: draft.to_s,
          user_input: user_input.to_s,
          user_supplied_tag: tag
        )
        Hive::Stages::Base.render("bot_brainstorm_codex_prompt.md.erb", bindings)
      end

      def spawn_with_base(task:, prompt:, config:)
        profile = Hive::Stages::Base.stage_profile(config, "develop")
        Hive::Stages::Base.spawn_agent(
          task,
          prompt: prompt,
          max_budget_usd: config.dig("bot", "codex_budget_usd") || 1,
          timeout_sec: config.dig("bot", "codex_timeout_sec") || 120,
          add_dirs: [ task.folder ],
          cwd: task.folder,
          log_label: "bot-codex",
          profile: profile,
          status_mode: :exit_code_only,
          cfg: config
        )
      end

      def parse_response(output)
        # Codex should emit one terminal BOT_* marker; if it emits more while
        # reasoning or revising, the last marker is the final operator-facing state.
        markers = output.lines.filter_map do |line|
          match = /\ABOT_(REPLY|DRAFT|ERROR):\s*(.*)\z/.match(line.strip)
          next unless match

          [ match[1], match[2] ]
        end
        return Result.new(kind: :error, reason: :unparseable) if markers.empty?

        kind, value = markers.last
        case kind
        when "REPLY"
          Result.new(kind: :reply, text: value)
        when "DRAFT"
          Result.new(kind: :draft_ready, draft: value)
        when "ERROR"
          Result.new(kind: :error, reason: value.empty? ? "codex_error" : value)
        end
      end

      def error(reason, task, question)
        @logger.event(:codex_failed, slug: task.slug, question_n: question.n,
                                     reason: reason.to_s)
        Result.new(kind: :error, reason: reason)
      end
    end
  end
end
