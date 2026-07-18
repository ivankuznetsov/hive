require "hive/bot/dispatch_request_writer"
require "hive/bot/brainstorm_answer_writer"
require "hive/bot/brainstorm_parser"
require "hive/bot/handlers/recovery_sequence"
require "hive/bot/notification_builders"
require "hive/commands/approve"
require "hive/commands/drop"
require "hive/commands/new"
require "hive/commands/status"
require "hive/lock"
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
        "ready_to_archive" => "archive",
        # Generic-workflow first-run rows dispatch the generic stage agent
        # via `hive run`; without this the web dispatcher rejected the new
        # `ready_to_run` action as unknown (422). `ready_to_advance` is
        # deliberately NOT mapped here: its verb is `hive approve`, which the
        # daemon dispatch-request queue's allowlist excludes (approve is
        # spawned in-process, not queued — see DispatchRequestQueue and the
        # bot supervisor). Generic advance is driven by the in-process
        # `#approve` method (the "Approve" button), not this queue path.
        "ready_to_run" => "run"
      }.freeze

      def initialize(dispatch_writer: Hive::Bot::DispatchRequestWriter)
        @dispatch_writer = dispatch_writer
      end

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

      # Canonical board mutation contract. The client supplies only a desired
      # destination and the semantic snapshot it rendered; core status derives
      # the exact verb. Synchronous moves revalidate again inside Approve's
      # owning commit lock, while run-class actions are durably queued with the
      # same guard for consume-time revalidation.
      def transition(slug:, project:, destination:, expected_fingerprint:, actor:,
                     request_id: Hive::Bot::DispatchRequestWriter.generate_request_id, reason: nil)
        raise Hive::Error, "destination is required" if destination.to_s.empty?
        raise Hive::Error, "expected fingerprint is required" if expected_fingerprint.to_s.empty?

        card = current_card(project: project, slug: slug)
        transition = exact_transition!(
          card, destination: destination, expected_fingerprint: expected_fingerprint
        )
        if %w[approve reject].include?(transition.fetch("verb"))
          result = Hive::Commands::Approve.new(
            slug,
            project: project,
            from: card.fetch("stage"),
            to: transition.fetch("destination"),
            force: transition["verb"] == "reject" || card["marker"] == "none",
            quiet: true,
            expected_fingerprint: expected_fingerprint,
            transition_verb: transition.fetch("verb"),
            audit: { actor: actor, request_id: request_id, reason: reason }
          ).call
          return { ok: true, state: "applied", request_id: request_id, transition: transition, result: result }
        end

        queue_transition!(
          card: card, transition: transition, project: project, slug: slug,
          expected_fingerprint: expected_fingerprint, actor: actor,
          request_id: request_id
        )
        { ok: true, state: "queued", request_id: request_id, transition: transition }
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

      # Drop = hard-delete the task, the parity of the TUI's Shift+X: kills
      # any running agent, removes the stage folder(s), worktree, and branch,
      # and closes a draft PR. Intentionally not an archive — no undo. `from`
      # scopes the resolve to the stage the operator was looking at, so a
      # stale page fails with a readable error instead of deleting a task
      # whose state has moved on.
      # Returns Drop's success payload so the controller can qualify its
      # notice — Drop degrades some cleanup steps to warnings (a draft PR
      # that would not close, an out-of-root worktree pointer), and those
      # warnings go to stderr, which the web operator never sees.
      def drop(slug:, project:, from: nil)
        Hive::Commands::Drop.new(slug, project: project, from: from, json: false).call
      end

      # Adapter so NotificationBuilders.recovery_match_attr (written against
      # the bot's row struct) reads a web status-row hash.
      RecoveryRow = Struct.new(:marker, :attrs)

      # Recovery = the bot's Autofix, web-shaped: clear the failure marker,
      # then re-run the stage verb — dispatched through the daemon queue as
      # ONE sequence, so the retry stays invisible until the clear exits 0
      # (true because a clear always precedes it — the guard above refuses
      # marker-less rows). RecoverySequence is the single source of truth
      # for the argvs and the manual-only guard, so web and bot recover
      # byte-identically; the TUI has its own subprocess-based clear +
      # `hive run` path with separate gates.
      def recover(slug:, project:, stage:, marker:, attrs: nil, workflow: nil)
        attrs = (attrs || {}).to_h.transform_keys(&:to_s)
        # No failure marker = nothing to recover. RecoverySequence would
        # skip the clear and queue a bare, UNGUARDED stage rerun behind a
        # "Recovery queued" notice — on a row that (since the controller
        # re-reads live state) already moved on. Refuse honestly instead.
        marker_name = marker.to_s.downcase
        if marker_name.empty? || %w[none agent_working].include?(marker_name)
          raise Hive::Error,
                "nothing to recover: #{slug} has no failure marker (its state changed — reload the page)"
        end
        if Hive::Bot::Handlers::RecoverySequence.manual_only?(marker, attrs)
          raise Hive::Error, Hive::Bot::Handlers::RecoverySequence.manual_only_text(marker, attrs)
        end

        match_attr = Hive::Bot::NotificationBuilders.recovery_match_attr(RecoveryRow.new(marker, attrs))
        commands = Hive::Bot::Handlers::RecoverySequence.retry_commands(
          project: project, slug: slug, stage: stage, marker: marker, match_attr: match_attr,
          workflow: workflow
        )
        raise Hive::Error, "no retry verb for stage #{stage.inspect}" if commands.empty?

        request_id = Hive::Bot::DispatchRequestWriter.generate_request_id
        first, *remaining = commands
        if remaining.any?
          Hive::Bot::DispatchRequestWriter.write_sequence!(request_id: request_id,
                                                           remaining_argvs: remaining)
        end
        begin
          Hive::Bot::DispatchRequestWriter.write!(project: project, slug: slug, argv: first,
                                                  trigger: "web_recover", request_id: request_id)
        rescue StandardError
          # Sequence-first is deliberate (request-first could let the daemon
          # finish the clear before the sidecar lands, silently skipping the
          # retry) — but it means a failed request write would orphan a
          # .sequence file nothing ever cleans. Mirror the bot supervisor:
          # discard, then let the error surface to the operator.
          if remaining.any?
            Hive::Bot::DispatchRequestWriter.discard_sequence!(request_id: request_id)
          end
          raise
        end
        request_id
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
        # `hive run` (generic-stage agent, from a `ready_to_run` row) scopes
        # the slug lookup with --stage and has no --from; every other
        # advance/approve verb asserts the source stage with --from.
        argv += [ verb == "run" ? "--stage" : "--from", stage ] if stage
        begin
          reference = @dispatch_writer.dispatch!(
            project: project,
            slug: slug,
            argv: argv,
            trigger: "web"
          )
        rescue ArgumentError => e
          # The queue's argv/slug grammar is stricter than the registry's
          # project-name rules — a name the web can render may still be
          # unqueueable. A typed error beats a 500 from the writer.
          raise Hive::Error, "cannot queue this dispatch: #{e.message}"
        end
        {
          ok: true,
          request_id: reference.request_id,
          attempt_id: reference.attempt_id,
          state: reference.state,
          dispatch_status: reference.status,
          argv: argv
        }
      end

      def repair_daemon
        request_id = Hive::Bot::DispatchRequestWriter.generate_request_id
        # Enqueued under the GLOBAL_MAINTENANCE_PROJECT sentinel, which the
        # daemon consumer special-cases (process_global_maintenance_request)
        # instead of dropping as unknown_project — so `hive daemon install
        # --force` actually runs end-to-end (R10/AE3).
        Hive::Bot::DispatchRequestWriter.write!(
          project: Hive::Daemon::DispatchRequestQueue::GLOBAL_MAINTENANCE_PROJECT,
          slug: "daemon-repair",
          argv: %w[hive daemon install --force],
          trigger: "web_daemon_repair",
          request_id: request_id
        )
        request_id
      rescue ArgumentError
        # Write-time guard only: the queue's argv/slug grammar rejects a
        # malformed request before it lands. Surface a typed error instead of
        # executing repair directly from a web worker.
        raise Hive::Error, "cannot queue daemon repair on this host; run `hive daemon install --force`"
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

      def current_card(project:, slug:)
        Hive::Commands::Status.new.task_card(project: project, slug: slug)
      end

      def exact_transition!(card, destination:, expected_fingerprint:)
        unless card["fingerprint"] == expected_fingerprint
          raise Hive::StaleTask.new(
            "task changed since the board rendered; review the current card and retry",
            expected_fingerprint: expected_fingerprint, current_card: card
          )
        end

        transition = Array(card["allowed_transitions"]).find do |candidate|
          candidate["destination"] == destination.to_s
        end
        return transition if transition

        raise Hive::StaleTask.new(
          "the requested destination is not currently allowed",
          expected_fingerprint: expected_fingerprint, current_card: card
        )
      end

      def queue_transition!(card:, transition:, project:, slug:, expected_fingerprint:, actor:, request_id:)
        project_entry = Hive::Config.find_project(project) ||
                        raise(Hive::InvalidTaskPath, "unknown project #{project}")
        Hive::Lock.with_commit_lock(project_entry.fetch("hive_state_path")) do
          fresh = current_card(project: project, slug: slug)
          exact = exact_transition!(
            fresh,
            destination: transition.fetch("destination"),
            expected_fingerprint: expected_fingerprint
          )
          unless exact["verb"] == transition["verb"]
            raise Hive::StaleTask.new(
              "the transition verb changed while the request was being admitted",
              expected_fingerprint: expected_fingerprint, current_card: fresh
            )
          end

          verb = exact.fetch("verb")
          argv = [ "hive", verb, slug, "--project", project ]
          argv += [ verb == "run" ? "--stage" : "--from", fresh.fetch("stage") ]
          @dispatch_writer.write!(
            project: project, slug: slug, argv: argv,
            requestor: "web", actor: actor, trigger: "web_transition",
            request_id: request_id, expected_fingerprint: expected_fingerprint,
            transition_destination: exact.fetch("destination")
          )
        end
      rescue ArgumentError => e
        raise Hive::Error, "cannot queue this transition: #{e.message}"
      end

      # Map the task's current stage dir (e.g. "6-review") to the directory # not-a-stage-ref: documentation example
      # of the stage immediately before it. An absent `from` falls back to
      # the first stage (a supported call shape), but an unparseable one
      # RAISES: reject runs forced, so "guess 1-inbox" would silently drag
      # a late-stage task back to the idea pile on a caller bug — the one
      # place a sane-fallback is less safe than failing.
      #
      # coding-scoped: web reject/backstage is a coding-only action today.
      # `Hive::Stages.parse`/`prev_dir`/`DIRS` all read the coding descriptor,
      # so a generic task's `from` raises "unknown stage" here rather than
      # being silently mis-routed to a coding gate. Descriptor-driven generic
      # reject is deferred to U7/U9 alongside the Rails reject button.
      def prior_gate(from)
        return Hive::Stages::DIRS.first if from.nil? || from.to_s.empty?

        parsed = Hive::Stages.parse(from)
        raise Hive::Error, "unknown stage #{from.inspect}" unless parsed

        Hive::Stages.prev_dir(parsed.first) || Hive::Stages::DIRS.first
      end
    end
  end
end
