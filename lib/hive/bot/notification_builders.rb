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
        ready_for_review
        ready_for_pr
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
              [ button("Show details", "details:#{row.project}:#{row.slug}") ],
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
              [ button("Show details", "details:#{row.project}:#{row.slug}") ]
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
            [ button("Show details", "details:#{row.project}:#{row.slug}") ]
          ]
        )
      end

      def recovery(row)
        keyboard =
          if open_laptop_only_recovery?(row)
            [
              [ button("Open laptop", "open_laptop:#{row.project}:#{row.slug}") ],
              [ button("Show details", "details:#{row.project}:#{row.slug}") ]
            ]
          else
            [
              [ button("Clear and retry", "clear_retry:#{row.project}:#{row.slug}:#{row.stage}:#{row.marker}") ],
              [ button("Open laptop", "open_laptop:#{row.project}:#{row.slug}") ],
              [ button("Show details", "details:#{row.project}:#{row.slug}") ]
            ]
          end
        Notification.new(
          text: header(row) + "\nNeeds recovery: #{marker_with_attrs(row)}",
          keyboard: keyboard
        )
      end

      def open_laptop_only_recovery?(row)
        attrs = row.attrs.to_h.transform_keys(&:to_s)
        row.marker.to_s == "review_error" &&
          attrs["phase"] == "fix" &&
          attrs["reason"] == "fix_tampered"
      end

      def header(row)
        "#{row.project}/#{row.slug} (#{row.stage})"
      end

      def marker_with_attrs(row)
        normalized = row.attrs.to_h.transform_keys(&:to_s)
        attrs = normalized.to_a.sort_by(&:first).map { |key, value| "#{key}=#{value}" }.join(" ")
        attrs.empty? ? row.marker : "#{row.marker} #{attrs}"
      end

      def verb_for_action(action)
        {
          "ready_to_brainstorm" => "brainstorm",
          "ready_to_plan" => "plan",
          "ready_to_develop" => "develop",
          "ready_for_review" => "review",
          "ready_for_pr" => "pr",
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
