require "hive/bot/notification_builders"
require "hive/recovery/retry_policy"

module Hive
  module Bot
    module Handlers
      # Builds the bot result for Autofix callbacks and slash commands.
      # Recoverable markers become one coordinator request; markerless
      # diagnostic retries remain ordinary workflow command dispatches.
      module RecoveryResultBuilder
        # Builds a full recovery Result for a row whose marker is known.
        # Short-circuits with an operator-facing reply when the marker is
        # manual-only or the stage has no retry verb.
        #
        # attrs is optional because callback paths carry only the encoded
        # marker match attributes while slash callers have the full row.
        # EXECUTE_STALE is the sole manual-only marker; ERROR and REVIEW_ERROR
        # always retain a guarded retry path.
        def self.build(project:, slug:, stage:, marker:, match_attr:, result_class:, clear_keyboard:,
                       attrs: nil, workflow: nil, row: nil)
          # `match_attr` is a single `key=value` pair the inline-button
          # path encoded into callback_data because the full row.attrs
          # hash doesn't survive a Telegram callback. Synthesise a
          # minimal attrs Hash from it for callers that inspect the resolved
          # marker context.
          resolved_attrs = attrs || attrs_from_match_attr(match_attr)
          folder = row.folder if row&.respond_to?(:folder)
          if Hive::Bot::NotificationBuilders.manual_only?(
            marker: marker, attrs: resolved_attrs, folder: folder
          )
            return result_class.new(action: :reply,
                                    text: Hive::Bot::NotificationBuilders.manual_only_reply(
                                      marker: marker, attrs: resolved_attrs, folder: folder
                                    ))
          end

          verb = Hive::Recovery::RetryPolicy.verb_for(
            stage, workflow: workflow, project: project
          )
          unless verb
            stage_label = stage.to_s.empty? ? "(empty)" : stage
            return result_class.new(action: :reply, text: "No retry verb for stage #{stage_label}.")
          end

          if %w[none agent_working].include?(marker.to_s.downcase)
            stage_flag = verb == "run" ? "--stage" : "--from"
            return result_class.new(
              action: :dispatch_commands,
              project: project,
              slug: slug,
              commands: [
                [ "hive", verb, slug, stage_flag, stage, "--project", project, "--json" ]
              ],
              alert_reset: alert_reset(project, slug, stage, marker, match_attr),
              clear_keyboard: clear_keyboard
            )
          end

          result_class.new(
            action: :dispatch_recovery,
            project: project,
            slug: slug,
            recovery: row || {
              project: project,
              slug: slug,
              stage: stage,
              workflow: workflow,
              marker: marker.to_s.downcase,
              attrs: resolved_attrs || {}
            },
            alert_reset: alert_reset(project, slug, stage, marker, match_attr),
            clear_keyboard: clear_keyboard
          )
        end

        # Inline keyboard callback_data carries `key=value` pairs via
        # `recovery_match_attr`, comma-separated when more than one is
        # encoded (e.g. `marker_id=abc,reason=ensure_clean_on_exit_failed`
        # — marker_id remains the race-safe clear guard while reason is an
        # additional assertion). Split each pair on the first `=` so a value like
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
