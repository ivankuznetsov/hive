require "digest"
require "json"
require "hive"

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
        review_findings
      ].freeze

      def build(row)
        if READY_ACTIONS.include?(row.action)
          stage_approval(row)
        elsif row.action == Hive::Schemas::TaskActionKind::NEEDS_INPUT
          needs_input(row)
        elsif recovery?(row)
          recovery(row)
        else
          nil
        end
      end

      def fingerprint(row)
        normalized_attrs = row.attrs.to_h.transform_keys(&:to_s).to_a.sort_by(&:first)
        Digest::SHA256.hexdigest(JSON.generate([ row.project, row.slug, row.marker, normalized_attrs ]))
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
              [ button("Show details", details_callback(row)) ],
              [ button("Open laptop", "open_laptop:#{row.project}:#{row.slug}") ]
            ]
          )
        end
      end

      def brainstorm_waiting(row)
        Notification.new(
          text: header(row) + "\nBrainstorm questions are waiting.",
          keyboard: [
            [ button("Answer in chat", "answer:#{row.project}:#{row.slug}") ],
            [ button("Ask Codex", "path_a_yes:#{row.project}:#{row.slug}") ],
            [ button("Open laptop", "open_laptop:#{row.project}:#{row.slug}") ]
          ]
        )
      end

      def review_waiting(row)
        normalized_attrs = row.attrs.to_h.transform_keys(&:to_s)
        if normalized_attrs["reason"] == "fix_guardrail"
          return Notification.new(
            text: header(row) + "\nReview fix guardrail tripped: #{marker_with_attrs(row)}",
            keyboard: [
              [ button("Open laptop", "open_laptop:#{row.project}:#{row.slug}") ],
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

      def recovery(row)
        # The "Refresh diagnosis" button is the bot-side parity of the
        # TUI's R keystroke: dispatches `hive status --diagnose <slug>
        # --write --force --json` so the configured execute AgentProfile
        # produces a fresh diagnostic verdict. Pairs with Show details
        # (which just reads the current verdict). Resolves issue #91.
        details_row = [
          button("Show details", details_callback(row)),
          button("Refresh diagnosis", refresh_diagnose_callback(row))
        ]
        keyboard =
          if open_laptop_only_recovery?(row)
            [
              [ button("Open laptop", "open_laptop:#{row.project}:#{row.slug}") ],
              details_row
            ]
          elsif markerless_retry_recovery?(row)
            [
              [ button("Retry", "clear_retry:#{row.project}:#{row.slug}:#{row.stage}:NONE") ],
              [ button("Open laptop", "open_laptop:#{row.project}:#{row.slug}") ],
              details_row
            ]
          else
            [
              [ button("Clear and retry", "clear_retry:#{row.project}:#{row.slug}:#{row.stage}:#{row.marker}") ],
              [ button("Open laptop", "open_laptop:#{row.project}:#{row.slug}") ],
              details_row
            ]
          end
        # Append the bounded diagnostic summary so the operator sees the
        # one-line "why is this red" without an extra round-trip through
        # the Show-details callback. StatusWatcher::Row carries the
        # diagnostic hash from `hive status --json`; nil when the row is
        # green or the snapshot pre-dates the schema. See PR #84 review
        # row 23.
        text = header(row) + "\nNeeds recovery: #{marker_with_attrs(row)}"
        if row.diagnostic.is_a?(Hash) && !row.diagnostic["summary"].to_s.empty?
          text += "\n\n#{row.diagnostic['summary']}"
        end
        Notification.new(text: text, keyboard: keyboard)
      end

      def open_laptop_only_recovery?(row)
        attrs = row.attrs.to_h.transform_keys(&:to_s)
        diagnostic_manual_fix?(row) ||
          stale_agent_working_pending_heal?(row) ||
          row.marker.to_s == "review_error" &&
            attrs["phase"] == "fix" &&
            attrs["reason"] == "fix_tampered"
      end

      # Stale AGENT_WORKING that TaskAction has reclassified as :error
      # but the daemon hasn't yet rewritten on disk. Rendering "Clear
      # and retry" here would dispatch `hive markers clear --name
      # AGENT_WORKING`, which is not in the markers-clear allowlist
      # (lib/hive/commands/markers.rb#ALLOWED_NAMES) and exits 4. Hide
      # the button; the daemon heals within one tick anyway, after
      # which the normal ERROR-recovery affordance fires.
      def stale_agent_working_pending_heal?(row)
        row.marker.to_s == "agent_working" && row.action.to_s == "error"
      end

      def markerless_retry_recovery?(row)
        row.marker.to_s == "none" && diagnostic_suggested_action(row)["kind"].to_s == "retry"
      end

      def diagnostic_manual_fix?(row)
        diagnostic_suggested_action(row)["kind"].to_s == "manual_fix"
      end

      def diagnostic_suggested_action(row)
        diagnostic = row.diagnostic
        return {} unless diagnostic.is_a?(Hash)

        suggested = diagnostic["suggested_next_action"]
        suggested.is_a?(Hash) ? suggested : {}
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

      def refresh_diagnose_callback(row)
        callback_with_stage("refresh_diagnose", row)
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
