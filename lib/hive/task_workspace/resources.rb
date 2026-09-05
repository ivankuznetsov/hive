require "hive/task_workspace"
require "hive/usage_db"

module Hive
  module TaskWorkspace
    class Resources
      def initialize(attempts_panel:, usage_reader: Hive::UsageDb, limits: Limits.new)
        @attempts_panel = attempts_panel
        @usage_reader = BoundedUsageReader.wrap(usage_reader, limits: limits)
        @limits = limits
      end

      def call
        attempts = Array(@attempts_panel["records"])
        guards = attempts.flat_map { |attempt| guards_for(attempt) }
        usage_records = attempts.map { |attempt| usage_for(attempt) }
        diagnostics = Array(@attempts_panel["diagnostics"]).dup
        unavailable = usage_records.select { |record| record["state"] == "unavailable" }
        degraded = usage_records.select { |record| %w[unavailable partial].include?(record["state"]) }
        unavailable.each do |record|
          diagnostics << {
            "source" => "usage_db", "reason" => "usage_unavailable",
            "attempt_id" => record["attempt_id"]
          }
        end
        usage_records.select { |record| record["truncated"] == true }.each do |record|
          diagnostics << {
            "source" => "usage_db", "reason" => "usage_truncated",
            "attempt_id" => record["attempt_id"]
          }
        end
        state = if attempts.empty?
          "missing"
        elsif degraded.any? || @attempts_panel["truncated"] == true
          "partial"
        elsif guards.any? { |guard| %w[exhausted retry-after].include?(guard["state"]) }
          guards.any? { |guard| guard["state"] == "exhausted" } ? "exhausted" : "retry-after"
        else
          "current"
        end
        {
          "state" => state,
          "records" => (guards + usage_records).sort_by do |record|
            [ record["attempt_id"].to_s, record["session_id"].to_s,
              record["record_kind"].to_s, record["kind"].to_s ]
          end,
          "diagnostics" => diagnostics,
          "truncated" => @attempts_panel["truncated"] == true
        }
      end

      private

      def guards_for(attempt)
        Array(attempt["sessions"]).flat_map do |session|
          configured = Array(session["guards"]).map { |guard| stringify(guard) }
          observation = stringify(session["resource_observation"] || {})
          if !observation.empty? && configured.none? { |guard| guard["kind"] == observation["kind"] }
            configured << observation.merge(
              "scope" => "session", "source" => "runtime_receipt",
              "enforcement" => observation["kind"] == "timeout" ? "controller" : "provider_account",
              "billing_semantics" => "not_applicable", "reset_at" => nil
            )
          end
          configured.map do |guard|
            guard = merge_observation(guard, observation)
            configured_value = number(guard["configured"])
            observed_value = number(guard["observed"])
            headroom = if trustworthy_headroom?(guard, configured_value, observed_value)
              [ configured_value - observed_value, 0 ].max
            end
            state = guard_state(guard, configured_value, observed_value)
            {
              "record_kind" => "guard",
              "attempt_id" => attempt["attempt_id"],
              "session_id" => session["session_id"],
              "kind" => guard["kind"], "unit" => guard["unit"],
              "scope" => guard["scope"], "source" => guard["source"],
              "enforcement" => guard["enforcement"],
              "billing_semantics" => guard["billing_semantics"],
              "configured" => configured_value, "observed" => observed_value,
              "headroom" => headroom, "reset_at" => guard["reset_at"],
              "retry_at" => guard["retry_at"], "state" => state,
              "label" => label_for(guard)
            }
          end
        end
      end

      def usage_for(attempt)
        response = if @usage_reader.respond_to?(:exact_attempt)
          @usage_reader.exact_attempt(
            attempt_id: attempt["attempt_id"], task_generation: attempt["task_generation"],
            project_slug: attempt["project_slug"], task_slug: attempt["task_slug"]
          )
        else
          @usage_reader.call(
            attempt_id: attempt["attempt_id"], task_generation: attempt["task_generation"],
            project_slug: attempt["project_slug"], task_slug: attempt["task_slug"]
          )
        end
        response = symbolize(response)
        unless response[:available] == true
          return {
            "record_kind" => "usage", "attempt_id" => attempt["attempt_id"],
            "state" => "unavailable", "sessions" => [], "totals" => nil,
            "unattributed_count" => response[:unattributed_count]
          }
        end

        sessions = Array(response[:sessions]).map { |row| symbolize(row) }
                    .select { |row| !row[:session_id].to_s.empty? }
                    .group_by { |row| row[:session_id].to_s }
                    .map do |session_id, duplicates|
          row = duplicates.max_by do |candidate|
            [ integer(candidate[:input]), integer(candidate[:output]), integer(candidate[:cached]) ]
          end
          {
            "session_id" => session_id, "model" => row[:model], "source" => row[:source],
            "input" => integer(row[:input]), "output" => integer(row[:output]),
            "cached" => integer(row[:cached])
          }
        end.sort_by { |row| row["session_id"] }
        if sessions.empty?
          truncated = response[:truncated] == true || response[:unattributed_truncated] == true
          return {
            "record_kind" => "usage", "attempt_id" => attempt["attempt_id"],
            "state" => response[:detail_expired] ? "expired" : (truncated ? "partial" : "missing"),
            "detail_expired" => response[:detail_expired] == true,
            "sessions" => [], "totals" => nil,
            "unattributed_count" => response[:unattributed_count],
            "unattributed_truncated" => response[:unattributed_truncated] == true,
            "truncated" => truncated
          }
        end
        totals = sessions.each_with_object(
          { "input" => 0, "output" => 0, "cached" => 0, "tokens" => 0 }
        ) do |row, sum|
          %w[input output cached].each { |key| sum[key] += row[key] }
          sum["tokens"] += row["input"] + row["output"]
        end
        truncated = response[:truncated] == true || response[:unattributed_truncated] == true
        {
          "record_kind" => "usage", "attempt_id" => attempt["attempt_id"],
          "state" => truncated ? "partial" : "current",
          "sessions" => sessions, "totals" => totals,
          "unattributed_count" => response[:unattributed_count],
          "unattributed_truncated" => response[:unattributed_truncated] == true,
          "truncated" => truncated
        }
      rescue StandardError
        {
          "record_kind" => "usage", "attempt_id" => attempt["attempt_id"],
          "state" => "unavailable", "sessions" => [], "totals" => nil,
          "unattributed_count" => nil
        }
      end

      def merge_observation(guard, observation)
        return guard unless guard["kind"] == observation["kind"]

        guard.merge(
          "observed" => observation["observed"],
          "retry_at" => observation["retry_at"] || guard["retry_at"]
        )
      end

      def guard_state(guard, configured, observed)
        return "retry-after" unless guard["retry_at"].to_s.empty?
        return "missing" if configured.nil? && observed.nil?
        return "exhausted" if configured && observed && observed >= configured

        "current"
      end

      def trustworthy_headroom?(guard, configured, observed)
        configured && observed &&
          %w[usd tokens launches seconds turns requests].include?(guard["unit"].to_s) &&
          guard["scope"].to_s == "session"
      end

      def label_for(guard)
        case guard["kind"]
        when "budget_equivalent_guard"
          "Configured budget-equivalent guard"
        when "monetary_api_cap"
          "Monetary API cap"
        when "timeout"
          "Session timeout"
        when "token_limit"
          "Token limit"
        when "launch_quota"
          "Launch quota"
        when "account_quota"
          "Provider account quota"
        when "provider_rate_limit"
          "Provider rate limit"
        else
          guard["kind"].to_s.tr("_", " ").capitalize
        end
      end

      def stringify(value)
        value.to_h.transform_keys(&:to_s)
      end

      def symbolize(value)
        value.to_h.transform_keys(&:to_sym)
      end

      def number(value)
        return nil if value.nil?

        number = Float(value)
        number % 1 == 0 ? number.to_i : number
      rescue ArgumentError, TypeError
        nil
      end

      def integer(value)
        [ Integer(value || 0), 0 ].max
      rescue ArgumentError, TypeError
        0
      end
    end
  end
end
