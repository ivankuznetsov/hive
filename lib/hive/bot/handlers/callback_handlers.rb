require "hive/bot/notification_builders"
require "hive/bot/idea_keyboards"
require "hive/bot/handlers/recovery_sequence"

module Hive
  module Bot
    module Handlers
      class CallbackHandlers
        def initialize(pending_ideas:, set_last_project:, conversation_store:, result_class:,
                       idea_draft_store: nil,
                       projects_provider: -> { [] },
                       status_snapshot_provider: -> { [] },
                       last_project: -> { nil },
                       logger: nil)
          @pending_ideas = pending_ideas
          @set_last_project = set_last_project
          @conversation_store = conversation_store
          @result_class = result_class
          @idea_draft_store = idea_draft_store
          @projects_provider = projects_provider
          @status_snapshot_provider = status_snapshot_provider
          @last_project = last_project
          @logger = logger
        end

        def handle(intent, update)
          data = update.callback_data.to_s
          case intent
          when :callback_approve then approve(data)
          when :callback_reject then @result_class.new(action: :reply, text: "Left unchanged.")
          when :callback_autofix then autofix(data)
          when :callback_clear_and_retry then clear_and_retry(data)
          when :callback_open_laptop then @result_class.new(action: :reply, text: "Open laptop for this one.")
          when :callback_show_details then show_details(data)
          when :callback_refresh_diagnose then refresh_diagnose(data)
          when :callback_answer then answer(data)
          when :callback_idea_project_pick then idea_project(data)
          when :callback_idea_voice_confirm then idea_voice_confirm(data)
          when :callback_idea_voice_discard then idea_voice_discard(data)
          when :callback_idea_done then commit_idea(data)
          when :callback_idea_skip then commit_idea(data)
          # Codex-draft flow is retired (deterministic Q-by-Q answering only).
          # Legacy path_a callbacks still land here from messages sent before
          # the removal; reply with the new path so the operator isn't stuck.
          when :callback_path_a_yes,
               :callback_path_a_just_type
            @result_class.new(action: :reply,
                              text: "The Codex draft flow was removed. Tap Answer in chat (or send /answer <slug>) " \
                                    "and reply with your answer; the bot will send the next question automatically.")
          when :callback_findings_accept_all then findings_toggle(data, "accept-finding")
          when :callback_findings_reject_all then findings_toggle(data, "reject-finding")
          when :callback_idea_project_new then idea_project_new(data)
          else @result_class.new(action: :reply, text: "Bot got confused - please retry from /queue.")
          end
        rescue ArgumentError => e
          @logger&.event(:callback_malformed, data: data, error_class: e.class.name, message: e.message)
          @result_class.new(action: :reply, text: "Bot got confused - please retry from /queue.")
        end

        private

        def approve(data)
          _prefix, verb, project, slug, stage = split_callback(data, 5)
          # `hive run` (the generic-stage agent, from a `ready_to_run` row)
          # scopes the slug lookup with --stage and has no --from; every
          # other advance/approve verb asserts the source stage with --from.
          stage_flag = verb == "run" ? "--stage" : "--from"
          @result_class.new(
            action: :dispatch_then_reply,
            project: project,
            slug: slug,
            command_argv: [ "hive", verb, slug, stage_flag, stage, "--project", project, "--json" ]
          )
        end

        def clear_and_retry(data)
          _prefix, project, slug, stage, marker, *rest = split_callback(data, [ 5, 6, 7 ])
          match_attr, workflow = recovery_tail(rest)
          # Legacy clear_retry: buttons (from messages predating the Autofix
          # rename) route here. Go through RecoverySequence.build, not
          # retry_commands directly, so a stale clear_retry on a manual-only
          # marker (e.g. EXECUTE_STALE) gets the same "open it on a laptop"
          # refusal the current Autofix paths enforce — rather than blindly
          # dispatching markers-clear + a retry verb against a state that has
          # no safe auto-recovery. callback_data carries no attrs, so this
          # uses the marker-only manual-only check (ALWAYS_MANUAL_MARKERS).
          RecoverySequence.build(
            project: project, slug: slug, stage: stage,
            marker: marker, match_attr: match_attr, workflow: workflow,
            result_class: @result_class, clear_keyboard: true
          )
        end

        def autofix(data)
          _prefix, project, slug, stage, marker, *rest = split_callback(data, [ 5, 6, 7 ])
          match_attr, workflow = recovery_tail(rest)
          RecoverySequence.build(
            project: project, slug: slug, stage: stage, marker: marker,
            match_attr: match_attr, workflow: workflow,
            result_class: @result_class, clear_keyboard: true
          )
        end

        def answer(data)
          _prefix, project, slug = split_callback(data, 3)
          @result_class.new(action: :start_answer, project: project, slug: slug, mode: :path_b)
        end

        def show_details(data)
          _prefix, project, slug, stage = split_callback(data, [ 3, 4 ])
          row, error = resolve_details_row(project: project, slug: slug, stage: stage)
          return @result_class.new(action: :reply, text: error) if error

          @result_class.new(action: :reply, text: Hive::Bot::NotificationBuilders.details_reply(row))
        end

        def refresh_diagnose(data)
          _prefix, project, slug, stage = split_callback(data, [ 3, 4 ])
          stage_argv = stage ? [ "--stage", stage ] : []
          # Bot-side parity of the TUI's R keystroke: spawn the
          # configured execute AgentProfile via --write so a fresh
          # diagnostic verdict is produced and written to
          # <task>/diagnostics/red-status.md. The reply renders the
          # refreshed Diagnostic envelope. --force bypasses the
          # marker_signature cache so Refresh means "ask again", matching
          # the TUI R keystroke. Resolves issue #91.
          @result_class.new(
            action: :dispatch_then_reply,
            project: project,
            slug: slug,
            command_argv: [ "hive", "status", "--diagnose", slug,
                            "--project", project, *stage_argv, "--write", "--force", "--json" ]
          )
        end

        def idea_project_new(data)
          _prefix, token = split_callback(data, 2)
          if @idea_draft_store
            draft = @idea_draft_store.find_by_token(token)
            @idea_draft_store.clear(chat_id: draft.chat_id) if draft
          else
            @pending_ideas.delete(token)
          end
          @result_class.new(
            action: :reply,
            text: "Registering a new project from the bot is out of MVP scope — run `hive init` on a laptop, then send /idea again."
          )
        end

        def idea_project(data)
          _prefix, project, token = split_callback(data, 3)
          return collect_files_for_draft(project, token) if @idea_draft_store

          entry = @pending_ideas.delete(token)
          idea_text = entry.is_a?(Hash) ? entry[:text] : entry
          return @result_class.new(action: :reply, text: "That idea picker expired. Send /idea <text> again.") unless idea_text

          @set_last_project.call(project)
          @result_class.new(
            action: :dispatch_then_reply,
            project: project,
            command_argv: [ "hive", "new", project, idea_text, "--json" ]
          )
        end

        def collect_files_for_draft(project, token)
          draft = @idea_draft_store.find_by_token(token)
          return @result_class.new(action: :reply, text: "That idea picker expired. Send /idea again.") unless draft

          @idea_draft_store.set_project(chat_id: draft.chat_id, project: project)
          if draft.origin == :voice && draft.attachments.empty?
            @set_last_project.call(project)
            return @result_class.new(action: :commit_idea, project: project,
                                     attachment: { chat_id: draft.chat_id }, clear_keyboard: true)
          end

          @idea_draft_store.enter_collecting(chat_id: draft.chat_id)
          @set_last_project.call(project)
          @result_class.new(
            action: :reply,
            text: "Send any files now, or press Done.",
            reply_markup: done_keyboard(token)
          )
        end

        def idea_voice_confirm(data)
          _prefix, token = split_callback(data, 2)
          draft = @idea_draft_store&.find_by_token(token)
          return @result_class.new(action: :reply, text: "That voice idea draft expired. Send the voice note again.") unless draft

          projects = @projects_provider.call
          if projects.empty?
            # No project to capture into: clear the voice draft now rather than
            # leaving it live in :awaiting_transcript_confirm, where the still-
            # shown Confirm/Discard keyboard would re-hit this same dead end.
            @idea_draft_store.clear(chat_id: draft.chat_id)
            return @result_class.new(action: :reply,
                                     text: "No Hive projects are registered yet. Run `hive init` on a laptop, then send the voice note again.")
          end

          @idea_draft_store.confirm_transcript(chat_id: draft.chat_id)
          @result_class.new(
            action: :reply,
            text: "Pick a project for the idea.",
            reply_markup: Hive::Bot::IdeaKeyboards.project_keyboard(projects, token, last_project: @last_project.call)
          )
        end

        def idea_voice_discard(data)
          _prefix, token = split_callback(data, 2)
          draft = @idea_draft_store&.find_by_token(token)
          @idea_draft_store.clear(chat_id: draft.chat_id) if draft
          @result_class.new(action: :reply, text: "Discarded - nothing captured.")
        end

        def commit_idea(data)
          _prefix, token = split_callback(data, 2)
          draft = @idea_draft_store&.find_by_token(token)
          return @result_class.new(action: :reply, text: "That idea draft expired. Send /idea again.") unless draft

          @result_class.new(action: :commit_idea, project: draft.project,
                            attachment: { chat_id: draft.chat_id }, clear_keyboard: true)
        end

        def done_keyboard(token)
          [
            [ { text: "Done", callback_data: "idea_done:#{token}" },
              { text: "Skip", callback_data: "idea_skip:#{token}" } ]
          ]
        end

        def findings_toggle(data, verb)
          _prefix, _kind, project, slug, stage = split_callback(data, 5)
          stage_argv = stage ? [ "--stage", stage ] : []
          retry_verb = RecoverySequence.retry_verb_for_stage(stage)
          retry_argv = retry_verb ? [ "hive", retry_verb, slug, "--from", stage, "--project", project, "--json" ] : nil
          commands = [
            [ "hive", verb, slug, "--all", *stage_argv, "--project", project, "--json" ]
          ]
          commands << retry_argv if retry_argv
          # The callback only carries (project, slug, stage), not marker — accept/reject
          # explicitly resolves every finding for the row, so the broad-delete behaviour
          # (no marker filter) matches operator intent: clear ALL alerts at this (project,
          # slug, stage) so a recurring same-fingerprint failure re-alerts cleanly.
          @result_class.new(
            action: :dispatch_commands,
            project: project,
            slug: slug,
            commands: commands,
            alert_reset: RecoverySequence.alert_reset(project, slug, stage),
            clear_keyboard: true
          )
        end

        def split_callback(data, expected)
          counts = Array(expected)
          parts = data.split(":", counts.max)
          raise ArgumentError, "malformed callback" unless counts.include?(parts.length)

          parts
        end

        def resolve_details_row(project:, slug:, stage:)
          snapshot = @status_snapshot_provider.call
          return [ nil, "Status is still loading — try again in a moment." ] if snapshot.nil?

          matches = Array(snapshot).select do |row|
            row.respond_to?(:project) && row.respond_to?(:slug) &&
              row.project == project && row.slug == slug &&
              (stage.nil? || row.stage.to_s == stage)
          end
          case matches.length
          when 0 then [ nil, "That task is no longer active — send /status to see current tasks." ]
          when 1 then [ matches.first, nil ]
          else [ nil, "That task is ambiguous — send /status to pick the current task." ]
          end
        rescue StandardError
          [ nil, "Status lookup failed — try again in a moment." ]
        end

        # The recovery callbacks (autofix / clear_and_retry) carry up to two
        # optional trailing tokens — a match_attr and a workflow id — in either
        # order. They're disambiguated by content: a match_attr is always a
        # `key=value` pair (contains `=`), a workflow id never contains `=`.
        # Coding rows omit the workflow token (nil ⟹ coding), so older 5/6-part
        # callbacks parse unchanged.
        def recovery_tail(rest)
          match_attr = rest.find { |token| token.to_s.include?("=") }
          workflow = rest.find { |token| !token.to_s.include?("=") }
          [ match_attr, workflow ]
        end
      end
    end
  end
end
