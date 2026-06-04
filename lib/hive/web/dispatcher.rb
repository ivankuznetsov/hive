require "hive/bot/dispatch_request_writer"
require "hive/bot/brainstorm_answer_writer"
require "hive/bot/brainstorm_parser"
require "hive/commands/approve"
require "hive/commands/new"
require "hive/stages"

module Hive
  module Web
    class Dispatcher
      STAGE_VERB_BY_ACTION = {
        "ready_to_brainstorm" => "brainstorm",
        "ready_to_plan" => "plan",
        "ready_to_develop" => "develop",
        "ready_to_open_pr" => "open-pr",
        "ready_for_review" => "review",
        "ready_to_artifacts" => "artifacts",
        "ready_to_finalize" => "finalize",
        "ready_to_archive" => "archive"
      }.freeze

      def approve(slug:, project:, from: nil, to: nil, force: false)
        Hive::Commands::Approve.new(
          slug,
          project: project,
          from: from,
          to: to,
          force: force,
          json: true
        ).call
      end

      # Reject = send a task back to its immediately-prior gate, the parity
      # of the TUI's reject (a backward recovery move). The destination is
      # derived from the task's current stage rather than hardcoding
      # 2-brainstorm, which would forcibly drag a late-stage task (e.g.
      # 6-review) all the way back to brainstorm. `force: true` because a
      # backward move is a deliberate recovery action that bypasses the
      # terminal-marker check. An explicit `to:` still wins for callers that
      # need to target a specific earlier stage.
      def reject(slug:, project:, from: nil, to: nil)
        destination = to || prior_gate(from)
        approve(slug: slug, project: project, from: from, to: destination, force: true)
      end

      def dispatch(slug:, project:, action:, stage: nil)
        verb = STAGE_VERB_BY_ACTION.fetch(action.to_s) { action.to_s }
        argv = [ "hive", verb, slug, "--project", project ]
        argv += [ "--from", stage ] if stage
        request_id = Hive::Bot::DispatchRequestWriter.write!(
          project: project,
          slug: slug,
          argv: argv,
          trigger: "web"
        )
        { ok: true, request_id: request_id, argv: argv }
      end

      # Write an operator's steer/answer into the task's brainstorm.md via
      # the same `BrainstormAnswerWriter` the Telegram bot uses, so the
      # daemon's answers-pending gate picks it up and resumes the stage.
      # Previously the web UI appended to a `web-interventions.md` file that
      # nothing consumes, silently dropping the message. The answer fills the
      # next unanswered question — parity with the bot's free-text reply
      # path (`Supervisor#execute_answer_write`).
      def intervene(folder:, message:)
        text = message.to_s.strip
        raise Hive::Error, "intervene message is required" if text.empty?

        brainstorm_path = File.join(folder.to_s, "brainstorm.md")
        unless File.file?(brainstorm_path)
          raise Hive::Error, "intervene is only available while a task awaits a brainstorm answer"
        end

        question = Hive::Bot::BrainstormParser.next_unanswered_question(
          Hive::Bot::BrainstormParser.parse(brainstorm_path)
        )
        raise Hive::Error, "no unanswered brainstorm question remains for this task" unless question

        result = Hive::Bot::BrainstormAnswerWriter.append!(
          brainstorm_path: brainstorm_path,
          question_n: question.n,
          answer_text: text
        )
        raise Hive::Error, "could not record answer (#{result})" unless result == :written

        { ok: true, question_n: question.n }
      end

      def new_idea(project:, text:)
        Hive::Commands::New.new(project, text).call
      end

      private

      # Map the task's current stage dir (e.g. "6-review") to the directory
      # of the stage immediately before it. Falls back to the first stage
      # when `from` is absent or unparseable so a reject still does something
      # sane rather than raising.
      def prior_gate(from)
        parsed = from && Hive::Stages.parse(from)
        return Hive::Stages::DIRS.first unless parsed

        Hive::Stages.prev_dir(parsed.first) || Hive::Stages::DIRS.first
      end
    end
  end
end
