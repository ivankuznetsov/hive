require_relative "reason_classifier"

module Hive
  module Eval
    module ContractAssertions
      def classified_messages
        Hive::Eval::ReasonClassifier.new(
          messages: harness.sent,
          log_events: harness.logger.respond_to?(:events) ? harness.logger.events : []
        ).classify_all
      end

      def assert_all_messages_typed
        bad = classified_messages.reject { |entry| Hive::Eval::ReasonClassifier::ALLOW_LIST.include?(entry.reason) }
        passed = bad.empty?
        record_eval_assertion(kind: "all_messages_typed", expected: Hive::Eval::ReasonClassifier::ALLOW_LIST,
                              actual: bad.map { |entry| assertion_detail(entry) }, passed: passed)
        assert passed, "unclassified Telegram messages:\n#{bad.map { |entry| assertion_detail(entry) }.join("\n")}"
      end

      def assert_proactive_rule
        bad = classified_messages.select do |entry|
          entry.proactive && !%w[agent_blocked_question fatal_error].include?(entry.reason)
        end
        passed = bad.empty?
        record_eval_assertion(kind: "proactive_rule",
                              expected: "proactive reasons limited to agent_blocked_question,fatal_error",
                              actual: bad.map { |entry| assertion_detail(entry) },
                              passed: passed)
        assert passed, "proactive messages violated allow-list:\n#{bad.map { |entry| assertion_detail(entry) }.join("\n")}"
      end

      def assert_no_duplicates(window_sec:)
        duplicates = duplicate_classifications(window_sec: window_sec)
        passed = duplicates.empty?
        record_eval_assertion(kind: "dedupe", expected: "no same reason+payload within #{window_sec}s",
                              actual: duplicates.map { |entry| assertion_detail(entry) }, passed: passed)
        assert passed, "duplicate Telegram payloads within #{window_sec}s:\n" \
                       "#{duplicates.map { |entry| assertion_detail(entry) }.join("\n")}"
      end

      def assert_sent_one(reason:)
        matches = classified_messages.select { |entry| entry.reason == reason.to_s }
        record_eval_assertion(kind: "sent_one", reason: reason.to_s, expected: 1,
                              actual: matches.length, passed: matches.length == 1)
        assert_equal 1, matches.length,
                     "expected exactly one #{reason} message, got #{matches.length}: " \
                     "#{classified_messages.map { |entry| [ entry.reason, entry.message.text ] }.inspect}"
        matches.first
      end

      def assert_no_message_with_reason(reason)
        matches = classified_messages.select { |entry| entry.reason == reason.to_s }
        record_eval_assertion(kind: "no_message_with_reason", reason: reason.to_s, expected: 0,
                              actual: matches.length, passed: matches.empty?)
        assert_empty matches, "expected no #{reason} messages, got #{matches.map { |entry| entry.message.text }.inspect}"
      end

      def refute_proactive_status_response
        matches = classified_messages.select { |entry| entry.proactive && entry.reason == "status_response" }
        record_eval_assertion(kind: "no_proactive_status_response", expected: 0,
                              actual: matches.length, passed: matches.empty?)
        assert_empty matches, "status_response must be pull-only: #{matches.map { |entry| entry.message.text }.inspect}"
      end

      private

      def duplicate_classifications(window_sec:)
        seen = Hash.new { |hash, key| hash[key] = [] }
        duplicates = []
        classified_messages.sort_by { |entry| entry.message.t }.each do |entry|
          key = [ entry.reason, entry.message.fingerprint ]
          cutoff = entry.message.t - window_sec
          seen[key].select! { |old| old.message.t >= cutoff }
          duplicates << entry unless seen[key].empty?
          seen[key] << entry
        end
        duplicates
      end

      def assertion_detail(entry)
        row = entry.message.row
        row_detail = row ? " row=#{row.project}/#{row.slug} action=#{row.action} marker=#{row.marker}" : ""
        "reason=#{entry.reason} proactive=#{entry.proactive} detail=#{entry.detail}#{row_detail} text=#{entry.message.text.inspect}"
      end

      def record_eval_assertion(kind:, expected:, actual:, passed:, reason: nil)
        return unless respond_to?(:eval_assertions)

        eval_assertions << {
          kind: kind,
          reason: reason,
          expected: expected,
          actual: actual,
          passed: passed
        }
      end
    end
  end
end
