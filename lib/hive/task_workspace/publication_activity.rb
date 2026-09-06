require "digest"
require "json"
require "time"
require "hive/gh"
require "hive/task_activity"

module Hive
  module TaskWorkspace
    # Converts a credential-scoped PublicationCache refresh into bounded,
    # task-local outcome observations. The cache remains advisory; only changed
    # normalized PR/check/review outcomes are journaled, never title/body text or
    # a credential-scoped payload.
    class PublicationActivity
      def initialize(task: nil, activity: nil, clock: -> { Time.now.utc })
        @activity = activity || (task && Hive::TaskActivity.for_task(task, clock: clock))
        @clock = clock
      end

      def record(before:, after:)
        return false unless @activity

        prior = observation(before)
        current = observation(after)
        return false unless current
        observed_at = observation_time(after)

        changed = false
        if current.fetch("state", "UNKNOWN") == "MERGED" && prior&.fetch("state", nil) != "MERGED"
          changed = record_kind(
            "merge_observed", current, merge_payload(current), observed_at: observed_at
          ) || changed
        elsif pr_fingerprint(prior) != pr_fingerprint(current)
          changed = record_kind(
            "pr_observed", current, common_payload(current), observed_at: observed_at
          ) || changed
        end
        if checks_fingerprint(prior) != checks_fingerprint(current)
          changed = record_kind(
            "check_observed", current, check_payload(current), observed_at: observed_at
          ) || changed
        end
        if prior && prior["review_decision"] != current["review_decision"]
          changed = record_kind(
            "review_observed", current, review_payload(current), observed_at: observed_at
          ) || changed
        end
        changed
      rescue Hive::TaskActivity::Error, JSON::GeneratorError, TypeError, ArgumentError
        false
      end

      private

      def observation(value)
        row = value.to_h.transform_keys(&:to_s)
        observed = row["observation"]
        observed.is_a?(Hash) ? observed.transform_keys(&:to_s) : nil
      rescue NoMethodError
        nil
      end

      def record_kind(kind, observation, payload, observed_at:)
        transition = payload.merge("transition_observed_at" => observed_at)
        identity = Digest::SHA256.hexdigest(JSON.generate(transition.sort.to_h))
        @activity.record(
          kind: kind, operation_id: "github:#{kind}:#{identity}",
          correlation_id: "publication:#{payload.fetch('pr_number')}",
          reason: "pull request #{kind.delete_suffix('_observed').tr('_', ' ')} outcome changed",
          source: "github", occurred_at: event_time(kind, observation, observed_at),
          observed_at: observed_at, payload: payload
        )
        true
      end

      def common_payload(row)
        parsed = Hive::Gh.parse_pull_request_url(row["url"])
        {
          "pr_number" => Integer(row["number"] || parsed&.fetch("number")),
          "pr_url" => parsed&.fetch("url"),
          "pr_state" => row.fetch("state", "UNKNOWN").to_s.downcase,
          "head_oid" => row["head_oid"], "draft" => row["is_draft"] == true
        }
      end

      def merge_payload(row)
        common_payload(row).merge(
          "merge_state" => "merged", "merge_oid" => row["merge_commit_oid"],
          "merged_at" => row["merged_at"]
        )
      end

      def check_payload(row)
        checks = Array(row["checks"])
        state = if checks.empty?
          "none"
        elsif checks.any? { |check| failing_check?(check) }
          "failing"
        elsif checks.all? { |check| successful_check?(check) }
          "passing"
        else
          "pending"
        end
        common_payload(row).merge("check_state" => state)
      end

      def review_payload(row)
        common_payload(row).merge("review_state" => row["review_decision"].to_s.downcase)
      end

      def pr_fingerprint(row)
        return nil unless row

        row.values_at("number", "url", "state", "is_draft", "head_oid", "merged_at",
                      "merge_commit_oid")
      end

      def checks_fingerprint(row)
        return nil unless row

        Array(row["checks"]).map do |check|
          normalized = check.to_h.transform_keys(&:to_s)
          normalized.values_at("name", "status", "conclusion")
        end.sort
      end

      def failing_check?(check)
        %w[FAILURE CANCELLED TIMED_OUT ACTION_REQUIRED STARTUP_FAILURE STALE].include?(
          check.to_h.transform_keys(&:to_s)["conclusion"].to_s.upcase
        )
      end

      def successful_check?(check)
        row = check.to_h.transform_keys(&:to_s)
        %w[COMPLETED SUCCESS NEUTRAL SKIPPED].include?(row["status"].to_s.upcase) &&
          %w[SUCCESS NEUTRAL SKIPPED].include?(row["conclusion"].to_s.upcase)
      end

      def observation_time(value)
        row = value.to_h.transform_keys(&:to_s)
        normalize_time(row["observed_at"] || @clock.call)
      end

      def event_time(kind, row, observed_at)
        value = kind == "merge_observed" ? row["merged_at"] : nil
        normalize_time(value || observed_at)
      end

      def normalize_time(value)
        (value.is_a?(Time) ? value : Time.iso8601(value.to_s)).utc.iso8601(6)
      end
    end
  end
end
