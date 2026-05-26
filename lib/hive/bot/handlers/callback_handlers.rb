require "hive/bot/handlers/recovery_sequence"

module Hive
  module Bot
    module Handlers
      class CallbackHandlers
        def initialize(pending_ideas:, set_last_project:, conversation_store:, result_class:,
                       logger: nil)
          @pending_ideas = pending_ideas
          @set_last_project = set_last_project
          @conversation_store = conversation_store
          @result_class = result_class
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
          # Codex-draft flow is retired (deterministic Q-by-Q answering only).
          # Legacy callbacks still land here from messages sent before the
          # removal; reply with the new path so the operator isn't stuck.
          when :callback_path_a_yes,
               :callback_path_a_just_type,
               :callback_codex_write_draft,
               :callback_codex_edit,
               :callback_codex_cancel
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
          @result_class.new(
            action: :dispatch_then_reply,
            project: project,
            slug: slug,
            command_argv: [ "hive", verb, slug, "--from", stage, "--project", project, "--json" ]
          )
        end

        def clear_and_retry(data)
          _prefix, project, slug, stage, marker, match_attr = split_callback(data, [ 5, 6 ])
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
            marker: marker, match_attr: match_attr,
            result_class: @result_class, clear_keyboard: true
          )
        end

        def autofix(data)
          _prefix, project, slug, stage, marker, match_attr = split_callback(data, [ 5, 6 ])
          RecoverySequence.build(
            project: project, slug: slug, stage: stage, marker: marker,
            match_attr: match_attr, result_class: @result_class, clear_keyboard: true
          )
        end

        def answer(data)
          _prefix, project, slug = split_callback(data, 3)
          @result_class.new(action: :start_answer, project: project, slug: slug, mode: :path_b)
        end

        def show_details(data)
          _prefix, project, slug, stage = split_callback(data, [ 3, 4 ])
          stage_argv = stage ? [ "--stage", stage ] : []
          # Replace the previous full-status dump with a targeted
          # `hive status --diagnose <slug>` so the bot reply renders the
          # bounded Diagnostic envelope (summary + detail) instead of
          # the whole snapshot. `--stage` disambiguates duplicate slugs
          # in the same project. See PR #84 review row 24.
          @result_class.new(
            action: :dispatch_then_reply,
            project: project,
            slug: slug,
            command_argv: [ "hive", "status", "--diagnose", slug,
                            "--project", project, *stage_argv, "--json" ]
          )
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
          @pending_ideas.delete(token)
          @result_class.new(
            action: :reply,
            text: "Registering a new project from the bot is out of MVP scope — run `hive init` on a laptop, then send /idea again."
          )
        end

        def idea_project(data)
          _prefix, project, token = split_callback(data, 3)
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
      end
    end
  end
end
