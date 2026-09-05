require "bigdecimal"
require "hive/model_pricing"
require "hive/usage_db"
require "hive/task_workspace"

module Hive
  module TaskWorkspace
    class Usage
      def initialize(project_slug:, task_slug:, attempts_panel: {}, usage_reader: Hive::UsageDb,
                     pricing: Hive::ModelPricing.new, limits: Limits.new)
        @scope = { project_slug: project_slug, task_slug: task_slug }
        @attempts_panel = attempts_panel.to_h
        @usage_reader = BoundedUsageReader.wrap(usage_reader, limits: limits)
        @pricing = pricing
      end

      def call
        response = symbolize(@usage_reader.task_usage(**@scope))
        unless response[:available] == true
          return unavailable_envelope([ diagnostic("usage_store_unavailable", detail: response[:reason]) ])
        end

        summaries = Array(response[:groups]).map { |row| symbolize(row) }
        return unavailable_envelope([]) if summaries.empty?

        # Attempts supply optional debug labels, never the accounting inventory.
        attempts = Array(@attempts_panel["records"]).to_h { |row| [ row["attempt_id"], row ] }
        sessions = Array(response[:sessions]).map do |raw|
          row = symbolize(raw)
          attempt = attempts[row[:attempt_id]] || {}
          detail = Array(attempt["sessions"]).find do |session|
            session["session_id"] == (row[:session_id] || row[:id])
          end || {}
          binding = {
            session_id: row[:session_id] || row[:id], attempt_id: row[:attempt_id],
            stage: row[:stage], outcome: attempt["outcome"] || attempt["state"],
            live: row[:ended_at].nil?, started_at: row[:started_at], usage: detail["usage"].to_h
          }
          session_record(binding, row, estimate_price(row, binding),
            input: available_count(row, :input), output: available_count(row, :output))
        end
        count = summaries.sum { |row| row.fetch(:sessions_count) }
        metered = summaries.sum { |row| row.fetch(:metered_sessions_count) }
        live = summaries.sum { |row| row.fetch(:live_sessions_count) }
        tokens = summary_tokens(summaries)
        coverage = live.positive? ? "pending" : (tokens["complete"] ? "complete" : "partial")
        price = aggregate_price(sessions, coverage)
        missing_detail = count - sessions.length
        if missing_detail.positive?
          price["observed_subtotal_usd"] ||= price.delete("subtotal_usd")
          price["subtotal_usd"] = nil
          price["coverage"] = price["observed_subtotal_usd"] ? "partial" : "unavailable"
          price["unpriced_sessions_count"] += missing_detail
          price["missing_dimensions"] |= [ "session_detail" ]
        end
        dimensions = summaries.map do |row|
          {
            "harness" => row[:agent], "actual_provider" => row[:actual_backend],
            "actual_model" => row[:actual_model] || row[:model],
            "billing_route" => normalized_billing_route(row[:billing_route])
          }
        end
        {
          "coverage" => coverage, "observed_subtotal" => coverage != "complete",
          "sessions_count" => count, "metered_sessions_count" => metered,
          "unmetered_sessions_count" => count - metered,
          "live_sessions_count" => live,
          "compacted_sessions_count" => response.fetch(:compacted_sessions_count),
          "details_truncated" => response[:truncated] == true,
          "tokens" => tokens,
          "harnesses" => compact_unique(dimensions, "harness"),
          "actual_providers" => compact_unique(dimensions, "actual_provider"),
          "actual_models" => compact_unique(dimensions, "actual_model"),
          "billing_routes" => compact_unique(dimensions, "billing_route"),
          "billing_route" => combined_billing_route(dimensions),
          "api_equivalent" => price, "sessions" => sessions,
          "groups" => grouped_sessions(sessions),
          "model_totals" => summaries.group_by do |row|
            [ row[:stage], row[:actual_backend], row[:actual_model] || row[:model] ]
          end.sort_by { |key, _| key.map(&:to_s) }.map do |(stage, provider, model), rows|
            { "stage" => stage, "provider" => provider, "model" => model,
              "sessions_count" => rows.sum { |row| row[:sessions_count] },
              "tokens" => summary_tokens(rows) }
          end,
          "diagnostics" => []
        }
      rescue StandardError => error
        unavailable_envelope([ diagnostic("usage_read_failed", detail: error.class.name) ])
      end

      private

      def summary_tokens(rows)
        metrics = Hive::UsageDb::METRICS - [ :cost ]
        values = metrics.to_h do |metric|
          [ metric.to_s, rows.sum { |row| row[metric] || 0 } ]
        end
        values["input_output"] = values.fetch("input") + values.fetch("output")
        values["complete"] = rows.all? { |row| row[:input_available] == 1 && row[:output_available] == 1 }
        values["unavailable"] = metrics.filter_map do |metric|
          metric.to_s unless rows.all? { |row| row[:"#{metric}_available"] == 1 }
        end
        values
      end

      def estimate_price(row, binding)
        dimensions = row[:pricing_dimensions] || binding.fetch(:usage)["pricing_dimensions"] || {}
        input = row.merge(
          started_at: row[:started_at] || binding.fetch(:started_at),
          pricing_dimensions: dimensions
        )
        result = if @pricing.respond_to?(:estimate)
          @pricing.estimate(input)
        else
          @pricing.call(input)
        end
        symbolize(result)
      rescue StandardError
        {
          coverage: "unavailable", subtotal_usd: nil, observed_subtotal_usd: nil,
          missing_dimensions: [ "pricing" ], provider: nil,
          canonical_model: nil, rate_basis: nil
        }
      end

      def session_record(binding, row, pricing, input:, output:)
        {
          "session_id" => binding.fetch(:session_id),
          "attempt_id" => binding.fetch(:attempt_id),
          "stage" => binding.fetch(:stage),
          "outcome" => binding.fetch(:outcome),
          "live" => binding.fetch(:live),
          "started_at" => row[:started_at] || binding.fetch(:started_at),
          "ended_at" => row[:ended_at],
          "harness" => row[:harness] || row[:agent],
          "actual_provider" => row[:actual_backend],
          "actual_model" => row[:actual_model] || row[:model],
          "billing_route" => normalized_billing_route(row[:billing_route]),
          "billing_evidence_source" => row[:billing_evidence_source] || "unavailable",
          "input" => input,
          "output" => output,
          "cache_read" => available_count(row, :cache_read),
          "cache_write" => available_count(row, :cache_write),
          "reasoning" => available_count(row, :reasoning),
          "api_equivalent" => {
            "coverage" => pricing[:coverage],
            "subtotal_usd" => pricing[:subtotal_usd],
            "observed_subtotal_usd" => pricing[:observed_subtotal_usd],
            "missing_dimensions" => Array(pricing[:missing_dimensions]),
            "rate_basis" => pricing[:rate_basis]
          },
          "provider_reported_cost" => provider_reported_cost(row)
        }
      end

      def aggregate_price(sessions, coverage)
        values = sessions.filter_map do |session|
          price = session.fetch("api_equivalent")
          price["subtotal_usd"] || price["observed_subtotal_usd"]
        end
        exact = values.reduce(BigDecimal("0"), :+)
        complete = coverage == "complete" && sessions.any? && sessions.all? do |session|
          session.dig("api_equivalent", "coverage") == "complete"
        end
        {
          "coverage" => if complete
            "complete"
                        elsif coverage == "pending"
            "pending"
                        else
            values.empty? ? "unavailable" : "partial"
                        end,
          "subtotal_usd" => complete ? exact : nil,
          "observed_subtotal_usd" => complete || values.empty? ? nil : exact,
          "priced_sessions_count" => values.length,
          "unpriced_sessions_count" => sessions.length - values.length,
          "missing_dimensions" => sessions.flat_map do |session|
            Array(session.dig("api_equivalent", "missing_dimensions"))
          end.uniq.sort,
          "currency" => "USD"
        }
      end

      def grouped_sessions(sessions)
        sessions.group_by { |session| [ session["stage"], session["outcome"] ] }
                .sort_by { |(stage, outcome), _| [ stage.to_s, outcome.to_s ] }
                .map do |(stage, outcome), rows|
          {
            "stage" => stage, "outcome" => outcome,
            "sessions" => rows.sort_by { |row| [ row["started_at"].to_s, row["session_id"] ] }
          }
        end
      end

      def available_count(row, category)
        return nil if row[:"#{category}_available"] == false
        return nil if row[category].nil?

        number = Integer(row[category])
        number.negative? ? nil : number
      rescue ArgumentError, TypeError
        nil
      end

      def provider_reported_cost(row)
        return nil if row[:cost_available] == false

        row[:provider_reported_cost] || row[:cost]
      end

      def combined_billing_route(sessions)
        routes = compact_unique(sessions, "billing_route")
        known = routes - [ "unknown" ]
        return "unknown" if known.empty?
        return known.first if known.length == 1 && !routes.include?("unknown")

        "mixed"
      end

      def normalized_billing_route(value)
        %w[api subscription].include?(value.to_s) ? value.to_s : "unknown"
      end

      def compact_unique(records, key)
        records.map { |record| record[key] }.compact.reject { |value| value.to_s.empty? }.uniq.sort
      end

      def unavailable_envelope(diagnostics)
        {
          "coverage" => "unavailable", "observed_subtotal" => false,
          "sessions_count" => 0, "metered_sessions_count" => 0,
          "unmetered_sessions_count" => 0, "live_sessions_count" => 0,
          "compacted_sessions_count" => 0, "model_totals" => [],
          "tokens" => nil, "harnesses" => [], "actual_providers" => [],
          "actual_models" => [], "billing_routes" => [], "billing_route" => "unknown",
          "api_equivalent" => {
            "coverage" => "unavailable", "subtotal_usd" => nil,
            "observed_subtotal_usd" => nil, "priced_sessions_count" => 0,
            "unpriced_sessions_count" => 0,
            "missing_dimensions" => [ "usage" ], "currency" => "USD"
          },
          "sessions" => [], "groups" => [], "diagnostics" => diagnostics
        }
      end

      def diagnostic(reason, **details)
        { "source" => "task_usage", "reason" => reason }.merge(
          details.reject { |_, value| value.nil? }.transform_keys(&:to_s)
        )
      end

      def symbolize(value)
        value.to_h.transform_keys(&:to_sym)
      end
    end
  end
end
