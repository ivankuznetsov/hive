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
        def self.build(project:, slug:, stage:, marker:, match_attr:, result_class:, clear_keyboard:)
          if manual_only?(marker)
            return result_class.new(action: :reply,
                                    text: "Hive has no automatic recovery for this state - open it on a laptop.")
          end

          verb = retry_verb_for_stage(stage)
          unless verb
            stage_label = stage.to_s.empty? ? "(empty)" : stage
            return result_class.new(action: :reply, text: "No retry verb for stage #{stage_label}.")
          end

          result_class.new(
            action: :dispatch_commands,
            project: project,
            slug: slug,
            commands: retry_commands(project: project, slug: slug, stage: stage,
                                     marker: marker, match_attr: match_attr),
            alert_reset: alert_reset(project, slug, stage, marker, match_attr),
            clear_keyboard: clear_keyboard
          )
        end

        def self.manual_only?(marker)
          Hive::Bot::NotificationBuilders.manual_only?(marker: marker)
        end

        def self.retry_verb_for_stage(stage)
          return nil if stage.to_s == "9-done"

          Hive::Workflows.verb_arriving_at(stage) || {
            "4-execute" => "develop",
            "5-review" => "review",
            "6-pr" => "pr"
          }[stage]
        end

        # 9-done returns an empty command list (no retry verb), and
        # AGENT_WORKING markers skip `hive markers clear` because that name
        # is outside the clear allowlist (markers.rb#ALLOWED_NAMES) and
        # would exit 4. Both branches intentionally diverge from the
        # pre-U7 clear_and_retry path.
        def self.retry_commands(project:, slug:, stage:, marker:, match_attr: nil)
          verb = retry_verb_for_stage(stage)
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
          commands << [ "hive", verb, slug, "--from", stage, "--project", project, "--json" ]
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
