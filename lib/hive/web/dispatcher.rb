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

      # Raise unless `action` maps to a known stage verb. Reused by the
      # dispatch route to fail fast with a clean 422 before anything is
      # enqueued; `dispatch` itself re-checks as defense in depth.
      def assert_dispatchable!(action)
        return if STAGE_VERB_BY_ACTION.key?(action.to_s)

        raise Hive::Error, "unknown dispatch action: #{action.inspect}"
      end

      def dispatch(slug:, project:, action:, stage: nil)
        # `fetch` with no fallback block raises KeyError on an unknown action
        # instead of passing the literal string through as a hive verb the
        # daemon can't run. The app's `rescue_from Hive::Error` handler
        # turns that into a 422 rather than an opaque 500 or a queued bad verb.
        verb = begin
          STAGE_VERB_BY_ACTION.fetch(action.to_s)
        rescue KeyError
          # Owned here so the app-level handler doesn't need a blanket
          # KeyError rescue (which would reclassify programming errors
          # anywhere in a request as 422 user errors).
          raise Hive::Error, "unknown dispatch action: #{action.inspect}"
        end
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

      # `call!` (not `call`): the CLI wrapper rescues typed errors and
      # `exit 1`, which inside a web worker surfaces as an opaque blank 500.
      # call! raises the typed Hive::Error subclasses the web tier already
      # maps to a readable error page. `attachments` is the same
      # [[src_path, dest_name], ...] contract the TUI uses — files land in
      # the task's assets/ dir next to the [imageN] placeholders in `text`.
      # Per-question answers from the web Q&A form: `answers` maps question
      # number => answer text. Each is validated against the CURRENT parse
      # (the daemon may have advanced rounds since the form rendered) and
      # written through the same BrainstormAnswerWriter the bot and the
      # free-text intervene path use. Blank answers are skipped so the
      # operator can answer a subset and return for the rest.
      def answer_questions(folder:, answers:)
        brainstorm_path = File.join(folder.to_s, "brainstorm.md")
        unless File.file?(brainstorm_path)
          raise Hive::Error, "answers are only available while a task awaits a brainstorm answer"
        end

        provided = (answers || {}).to_h
                                  .transform_keys { |k| Integer(k, exception: false) }
                                  .transform_values { |v| v.to_s.strip }
                                  .reject { |n, text| n.nil? || text.empty? }
        raise Hive::Error, "no answers provided" if provided.empty?

        open_numbers = Hive::Bot::BrainstormParser.unanswered_questions(
          Hive::Bot::BrainstormParser.parse(brainstorm_path)
        ).map(&:n)
        stale = provided.keys - open_numbers
        unless stale.empty?
          raise Hive::Error,
                "question(s) #{stale.sort.join(", ")} are no longer open — the brainstorm may have moved on; reload the page"
        end

        provided.keys.sort.each do |n|
          result = Hive::Bot::BrainstormAnswerWriter.append!(
            brainstorm_path: brainstorm_path,
            question_n: n,
            answer_text: provided[n]
          )
          raise Hive::Error, "could not record answer to Q#{n} (#{result})" unless result == :written
        end

        { ok: true, answered: provided.keys.sort }
      end

      def new_idea(project:, text:, attachments: [])
        Hive::Commands::New.new(project, text, attachments: attachments).call!
      end

      private

      # Map the task's current stage dir (e.g. "6-review") to the directory
      # of the stage immediately before it. An absent `from` falls back to
      # the first stage (a supported call shape), but an unparseable one
      # RAISES: reject runs forced, so "guess 1-inbox" would silently drag
      # a late-stage task back to the idea pile on a caller bug — the one
      # place a sane-fallback is less safe than failing.
      def prior_gate(from)
        return Hive::Stages::DIRS.first if from.nil? || from.to_s.empty?

        parsed = Hive::Stages.parse(from)
        raise Hive::Error, "unknown stage #{from.inspect}" unless parsed

        Hive::Stages.prev_dir(parsed.first) || Hive::Stages::DIRS.first
      end
    end
  end
end
