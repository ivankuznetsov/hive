require "hive/workflows"
require "hive/bot/notification_builders"

module Hive
  module Bot
    module Handlers
      # Single source of truth for the "recover from a stuck task" dispatch
      # logic. Used by the inline-keyboard Autofix button path
      # (CallbackHandlers#autofix), the legacy Clear-and-retry callback path
      # (CallbackHandlers#clear_and_retry), and the /autofix slash command
      # path (SlashHandlers#autofix). Keeping all three surfaces routed
      # through this module ensures they dispatch byte-identical argvs for
      # the same row.
      module RecoverySequence
        # Builds a full recovery Result for a row whose marker is known.
        # Short-circuits with an operator-facing reply when the marker is
        # manual-only or the stage has no retry verb.
        #
        # attrs is optional: the inline-button / clear-and-retry callback
        # paths only carry the marker (the callback_data does not encode the
        # full attrs hash), so they pass nil and fall back to the marker-only
        # ALWAYS_MANUAL_MARKERS check. The /autofix slash command has the full
        # row in hand and passes row.attrs, which additionally catches the
        # attrs-gated manual-only states (e.g. review_error + phase=fix +
        # reason=fix_tampered) so a directly-typed /autofix on such a row
        # refuses with the "open it on a laptop" reply instead of dispatching
        # a retry against a tampered fix.
        def self.build(project:, slug:, stage:, marker:, match_attr:, result_class:, clear_keyboard:,
                       attrs: nil, workflow: nil)
          # `match_attr` is a single `key=value` pair the inline-button
          # path encoded into callback_data because the full row.attrs
          # hash doesn't survive a Telegram callback. Synthesise a
          # minimal attrs Hash from it so the attrs-gated manual-only
          # rules (review_error+fix_tampered, error+dirty_worktree,
          # error+ensure_clean_on_exit_failed) refuse on the callback
          # path too — not only the slash-handler path that already
          # passes the full row.attrs.
          resolved_attrs = attrs || attrs_from_match_attr(match_attr)
          if manual_only?(marker, resolved_attrs)
            return result_class.new(action: :reply,
                                    text: manual_only_text(marker, resolved_attrs))
          end

          verb = retry_verb_for_stage(stage, workflow: workflow)
          unless verb
            stage_label = stage.to_s.empty? ? "(empty)" : stage
            return result_class.new(action: :reply, text: "No retry verb for stage #{stage_label}.")
          end

          result_class.new(
            action: :dispatch_commands,
            project: project,
            slug: slug,
            commands: retry_commands(project: project, slug: slug, stage: stage,
                                     marker: marker, match_attr: match_attr, workflow: workflow),
            alert_reset: alert_reset(project, slug, stage, marker, match_attr),
            clear_keyboard: clear_keyboard
          )
        end

        def self.manual_only?(marker, attrs = nil)
          Hive::Bot::NotificationBuilders.manual_only?(marker: marker, attrs: attrs)
        end

        def self.manual_only_text(marker, attrs)
          Hive::Bot::NotificationBuilders.manual_only_reply(marker: marker, attrs: attrs)
        end

        # Inline keyboard callback_data carries `key=value` pairs via
        # `recovery_match_attr`, comma-separated when more than one is
        # encoded (e.g. `marker_id=abc,reason=ensure_clean_on_exit_failed`
        # — both tokens are needed so `manual_only?` can route on
        # `reason` while `marker_id` remains the race-safe clear
        # guard). Split each pair on the first `=` so a value like
        # `foo=bar=baz` keeps the trailing `=baz` intact.
        def self.attrs_from_match_attr(match_attr)
          raw = match_attr.to_s
          return nil unless raw.include?("=")

          attrs = {}
          raw.split(",").each do |pair|
            next unless pair.include?("=")

            key, value = pair.split("=", 2)
            key = key.to_s.strip
            attrs[key] = value unless key.empty?
          end
          attrs.empty? ? nil : attrs
        end

        def self.retry_verb_for_stage(stage, workflow: nil)
          stage = stage.to_s
          # A non-coding workflow has one universal re-run verb: `hive run`
          # (the generic stage runner). Routes here when the caller carries
          # the row's workflow (slash /autofix, web recover, and the inline
          # Autofix button now that its callback_data threads the id). When
          # the workflow is nil/coding the coding verb table applies unchanged
          # (an unknown/empty stage still yields nil → "No retry verb").
          unless Hive::Workflows.coding_id?(workflow)
            # The terminal stage has no agent to re-run — offering `hive run`
            # there would dispatch `hive run --stage <terminal>` and raise
            # StageError. Guard it the way the coding path guards `9-done` below.
            return nil if generic_terminal_stage?(stage, workflow)

            return "run"
          end
          return nil if stage == "9-done" # coding-scoped: coding retry verbs have no terminal retry

          Hive::Workflows.verb_arriving_at(stage) || {
            "5-review" => "review", # not-a-stage-ref: defensive fallback, reached only when verb_arriving_at returns nil (legacy/renamed dirs)
            "6-pr" => "pr" # not-a-stage-ref: defensive fallback, reached only when verb_arriving_at returns nil (legacy/renamed dirs)
          }[stage]
        end

        # True when `stage` is the terminal (last) stage of a registered
        # non-coding workflow — the generic analog of the coding `9-done`
        # guard. An unregistered workflow id (none ship in production yet)
        # can't be introspected, so it conservatively reports false and the
        # caller falls back to offering `hive run`.
        def self.generic_terminal_stage?(stage, workflow)
          descriptor = Hive::Workflows::Registry.fetch(workflow.to_s.to_sym)
          last = descriptor.stages.last
          !last.nil? && last.dir == stage
        rescue Hive::Workflows::UnknownWorkflow
          false
        end

        # 9-done returns an empty command list (no retry verb), and
        # AGENT_WORKING markers skip `hive markers clear` because that name
        # is outside the clear allowlist (markers.rb#ALLOWED_NAMES) and
        # would exit 4. Both branches intentionally diverge from the
        # pre-U7 clear_and_retry path.
        def self.retry_commands(project:, slug:, stage:, marker:, match_attr: nil, workflow: nil)
          verb = retry_verb_for_stage(stage, workflow: workflow)
          return [] unless verb

          commands = []
          marker_name = marker.to_s
          unless marker_name.casecmp("none").zero? || marker_name.casecmp("agent_working").zero?
            clear_argv = [ "hive", "markers", "clear", slug, "--name", marker_name.upcase,
                           "--project", project ]
            clear_argv += [ "--match-attr", match_attr ] if match_attr.to_s.include?("=")
            clear_argv << "--json"
            commands << clear_argv
          end
          # `hive run` (the generic stage runner) scopes by --stage and has no
          # --from; the coding advance/recovery verbs assert the source stage
          # with --from.
          stage_flag = verb == "run" ? "--stage" : "--from"
          commands << [ "hive", verb, slug, stage_flag, stage, "--project", project, "--json" ]
          commands
        end

        def self.alert_reset(project, slug, stage, marker = nil, match_attr = nil)
          payload = { project: project, slug: slug, stage: stage }
          payload[:marker] = marker if marker && !marker.to_s.empty?
          payload[:match_attr] = match_attr if match_attr && !match_attr.to_s.empty?
          payload
        end
      end
    end
  end
end
