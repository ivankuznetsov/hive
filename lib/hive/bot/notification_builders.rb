require "digest"
require "json"
require "hive"
require "hive/bot/title_formatter"

module Hive
  module Bot
    module NotificationBuilders
      module_function

      READY_ACTIONS = %w[
        ready_to_brainstorm
        ready_to_plan
        ready_to_develop
        ready_to_open_pr
        ready_for_review
        ready_to_artifacts
        ready_to_finalize
        ready_to_archive
      ].freeze

      INPUT_ACTIONS = %w[
        needs_input
        recover_execute
        recover_review
        error
      ].freeze

      SKIP_ACTIONS = %w[
        agent_running
        archived
      ].freeze

      def build(row, logger: nil)
        if READY_ACTIONS.include?(row.action)
          stage_approval(row)
        elsif row.action == Hive::Schemas::TaskActionKind::NEEDS_INPUT
          needs_input(row)
        elsif recovery?(row)
          recovery(row, logger: logger)
        else
          nil
        end
      end

      def fingerprint(row)
        normalized_attrs = row.attrs.to_h.transform_keys(&:to_s).to_a.sort_by(&:first)
        Digest::SHA256.hexdigest(JSON.generate([ row.project, row.slug, row.stage, row.marker, normalized_attrs ]))
      end

      def recovery?(row)
        %w[recover_execute recover_review error].include?(row.action) ||
          %w[review_error review_stale review_ci_stale execute_stale error].include?(row.marker)
      end

      def stage_approval(row)
        verb = verb_for_action(row.action)
        return nil unless verb

        Notification.new(
          text: header(row) + "\nReady for #{verb}.",
          keyboard: [
            [ button("Approve", "approve:#{verb}:#{row.project}:#{row.slug}:#{row.stage}") ],
            [ button("Reject", "reject:#{row.project}:#{row.slug}") ]
          ]
        )
      end

      def needs_input(row)
        case row.marker
        when "waiting"
          brainstorm_waiting(row)
        when "review_waiting"
          review_waiting(row)
        else
          Notification.new(
            text: header(row) + "\nNeeds input: #{marker_with_attrs(row)}",
            keyboard: [
              [ button("Show details", details_callback(row)) ]
            ]
          )
        end
      end

      def brainstorm_waiting(row)
        Notification.new(
          text: header(row) + "\n" \
                "Brainstorm questions are waiting. " \
                "Tap Answer in chat or reply with /answer #{row.slug} to provide input.",
          keyboard: [
            [ button("Answer in chat", "answer:#{row.project}:#{row.slug}") ]
          ]
        )
      end

      def review_waiting(row)
        normalized_attrs = row.attrs.to_h.transform_keys(&:to_s)
        if normalized_attrs["reason"] == "fix_guardrail"
          return Notification.new(
            text: header(row) + "\nReview fix guardrail tripped: #{marker_with_attrs(row)}",
            keyboard: [
              [ button("Show details", details_callback(row)) ]
            ]
          )
        end

        Notification.new(
          text: header(row) + "\nReview triage is waiting.",
          keyboard: [
            [
              button("Accept all", "findings:accept_all:#{row.project}:#{row.slug}:#{row.stage}"),
              button("Reject all", "findings:reject_all:#{row.project}:#{row.slug}:#{row.stage}")
            ],
            [ button("Show details", details_callback(row)) ]
          ]
        )
      end

      def recovery(row, logger: nil)
        retryable = retryable_recovery?(row)
        Notification.new(
          text: [
            "⚠ #{TitleFormatter.stage_label(row.stage, logger: logger)} stuck — \"#{TitleFormatter.title_from_slug(row.slug)}\"",
            cause_sentence_for(row),
            retryable ? "Tap Autofix to retry the stage cleanly." :
              "Tap Show details to see what needs manual intervention."
          ].join("\n"),
          keyboard: recovery_keyboard(row, retryable: retryable)
        )
      end

      def recovery_keyboard(row, retryable:)
        if retryable
          [ [ button("🔧 Autofix", autofix_callback(row)) ] ]
        else
          [
            [ button("Show details", details_callback(row)) ]
          ]
        end
      end

      def autofix_callback(row)
        parts = [ "autofix", row.project, row.slug, row.stage, row.marker ]
        match_attr = recovery_match_attr(row)
        parts << match_attr if match_attr
        parts.join(":")
      end

      def retryable_recovery?(row)
        return false if manual_only_recovery?(row)

        suggested = suggested_next_action(row)
        suggested && suggested["kind"].to_s == "retry"
      end

      # Markers that are ALWAYS manual-only regardless of attrs. Adding a new
      # marker here automatically narrows both the in-row recovery check
      # (manual_only_recovery?) and the recover-sequence dispatch guard
      # (RecoverySequence.build, used by the inline Autofix button and the
      # /autofix slash command) — they share this constant through
      # manual_only? below.
      ALWAYS_MANUAL_MARKERS = %w[execute_stale].freeze

      # Single source of truth for "this state has no auto-recovery".
      # Pass attrs: nil from callers that only have the marker name
      # (e.g. callback handlers); pass row.attrs from in-process checks
      # where the full attrs hash is available.
      def manual_only?(marker:, attrs: nil)
        marker = marker.to_s.downcase
        return true if ALWAYS_MANUAL_MARKERS.include?(marker)
        return false if attrs.nil?

        attrs = attrs.to_h.transform_keys(&:to_s)
        marker == "review_error" && attrs["phase"] == "fix" && attrs["reason"] == "fix_tampered"
      end

      def manual_only_recovery?(row)
        manual_only?(marker: row.marker, attrs: row.attrs)
      end

      def suggested_next_action(row)
        diagnostic = row.respond_to?(:diagnostic) ? row.diagnostic : nil
        return nil unless diagnostic.is_a?(Hash)

        suggested = diagnostic["suggested_next_action"]
        suggested.is_a?(Hash) ? suggested : nil
      end

      def recovery_match_attr(row)
        attrs = row.attrs.to_h.transform_keys(&:to_s)
        keys = case row.marker.to_s.downcase
        when "review_error", "review_ci_stale"
                 %w[pass phase reason]
        when "review_stale"
                 %w[pass reason]
        when "error"
                 %w[exit_code]
        else
                 []
        end
        key = keys.find { |candidate| !attrs[candidate].to_s.empty? }
        key ? "#{key}=#{attrs[key]}" : nil
      end

      def cause_sentence_for(row)
        case row.marker.to_s.downcase
        when "review_error"
          "The review agent crashed before it could finish."
        when "execute_stale"
          "The execute agent stalled before it could finish."
        when "review_stale", "review_ci_stale"
          "The review run stalled before it could finish."
        else
          "The agent crashed before it could finish."
        end
      end

      def header(row)
        "#{row.project}/#{row.slug} (#{row.stage})"
      end

      def marker_with_attrs(row)
        normalized = row.attrs.to_h.transform_keys(&:to_s)
        attrs = normalized.to_a.sort_by(&:first).map { |key, value| "#{key}=#{value}" }.join(" ")
        attrs.empty? ? row.marker : "#{row.marker} #{attrs}"
      end

      def details_callback(row)
        callback_with_stage("details", row)
      end

      def callback_with_stage(prefix, row)
        parts = [ prefix, row.project, row.slug ]
        stage = row.respond_to?(:stage) ? row.stage.to_s : ""
        parts << stage unless stage.empty?
        parts.join(":")
      end

      def verb_for_action(action)
        {
          "ready_to_brainstorm" => "brainstorm",
          "ready_to_plan" => "plan",
          "ready_to_develop" => "develop",
          "ready_to_open_pr" => "open-pr",
          "ready_for_review" => "review",
          "ready_to_artifacts" => "artifacts",
          "ready_to_finalize" => "finalize",
          "ready_to_archive" => "archive"
        }[action]
      end

      CALLBACK_DATA_MAX = 64
      CALLBACK_REGISTRY_TTL_SEC = 3600
      CALLBACK_REGISTRY_MAX = 2048

      def button(text, callback_data)
        { text: text, callback_data: compact_callback(callback_data) }
      end

      def compact_callback(callback_data)
        return callback_data if callback_data.bytesize <= CALLBACK_DATA_MAX

        prefix, _ = callback_data.split(":", 2)
        digest = Digest::SHA256.hexdigest(callback_data)[0, 16]
        prune_registry!
        registry[digest] = [ callback_data, Time.now ]
        "##{prefix}:#{digest}"
      end

      def resolve_callback(token)
        return token unless token.start_with?("#")

        _, digest = token.split(":", 2)
        entry = registry[digest]
        entry.is_a?(Array) ? entry.first : token
      end

      def registry
        @registry ||= {}
      end

      def prune_registry!
        cutoff = Time.now - CALLBACK_REGISTRY_TTL_SEC
        registry.delete_if { |_digest, entry| entry.is_a?(Array) && entry.last < cutoff }
        registry.shift while registry.size > CALLBACK_REGISTRY_MAX
      end

      Notification = Data.define(:text, :keyboard)
    end
  end
end
