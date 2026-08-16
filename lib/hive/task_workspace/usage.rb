require "bigdecimal"
require "hive/model_pricing"
require "hive/usage_db"

module Hive
  module TaskWorkspace
    class Usage
      def initialize(attempts_panel:, usage_reader: Hive::UsageDb,
                     pricing: Hive::ModelPricing.new)
        @attempts_panel = attempts_panel.to_h
        @usage_reader = usage_reader
        @pricing = pricing
      end

      def call
        attempts = Array(@attempts_panel["records"])
        inventory, diagnostics = inventory_for(attempts)
        return unavailable_envelope(diagnostics) if inventory.empty?

        rows_by_session = {}
        excluded_attributed = 0
        unattributed_counts = []
        read_unavailable = false
        attempts.each do |attempt|
          response = exact_usage(attempt)
          unless truthy(response[:available])
            read_unavailable = true
            diagnostics << diagnostic(
              "usage_store_unavailable", attempt_id: attempt["attempt_id"],
              detail: response[:reason]
            )
            next
          end
          unattributed_counts << Integer(response[:unattributed_count]) unless
            response[:unattributed_count].nil?
          grouped_rows(response[:sessions]).each do |session_id, row|
            binding = inventory[session_id]
            if binding.nil? || binding.fetch(:attempt_id) != attempt["attempt_id"].to_s
              excluded_attributed += 1
              diagnostics << diagnostic(
                "usage_session_not_in_durable_inventory", session_id: session_id,
                attempt_id: attempt["attempt_id"]
              )
              next
            end
            rows_by_session[session_id] = richer_row(rows_by_session[session_id], row)
          end
        rescue StandardError => e
          read_unavailable = true
          diagnostics << diagnostic(
            "usage_read_failed", attempt_id: attempt["attempt_id"], detail: e.class.name
          )
        end

        sessions = []
        unmetered = 0
        live = 0
        token_missing = 0
        inventory.each_value do |binding|
          row = rows_by_session[binding.fetch(:session_id)]
          live += 1 if binding.fetch(:live)
          unless row
            unmetered += 1 unless binding.fetch(:live)
            sessions << unmetered_session(binding)
            next
          end

          pricing = estimate_price(row, binding)
          input = available_count(row, :input)
          output = available_count(row, :output)
          token_missing += 1 if input.nil? || output.nil?
          sessions << session_record(binding, row, pricing, input:, output:)
        end

        truncated = @attempts_panel["truncated"] == true
        diagnostics << diagnostic("attempt_inventory_truncated") if truncated
        price_missing = sessions.count do |session|
          !%w[complete pending].include?(session.dig("api_equivalent", "coverage"))
        end
        inventory_conflict = diagnostics.any? do |row|
          row["reason"] == "session_bound_to_multiple_attempts"
        end
        coverage = if live.positive?
          "pending"
        elsif truncated || read_unavailable || unmetered.positive? ||
            excluded_attributed.positive? || token_missing.positive? || price_missing.positive? ||
            inventory_conflict ||
            !%w[current].include?(@attempts_panel["state"].to_s)
          "partial"
        else
          "complete"
        end

        api_equivalent = aggregate_price(sessions, coverage)
        {
          "coverage" => coverage,
          "observed_subtotal" => coverage != "complete",
          "sessions_count" => inventory.length,
          "metered_sessions_count" => rows_by_session.keys.count { |id| inventory.key?(id) },
          "unmetered_sessions_count" => unmetered,
          "live_sessions_count" => live,
          "excluded_attributed_sessions_count" => excluded_attributed,
          "unattributed_legacy_count" => unattributed_counts.empty? ? nil : unattributed_counts.max,
          "tokens" => aggregate_tokens(sessions),
          "harnesses" => compact_unique(sessions, "harness"),
          "actual_providers" => compact_unique(sessions, "actual_provider"),
          "actual_models" => compact_unique(sessions, "actual_model"),
          "billing_routes" => compact_unique(sessions, "billing_route"),
          "billing_route" => combined_billing_route(sessions),
          "api_equivalent" => api_equivalent,
          "sessions" => sessions.sort_by do |session|
            [ session["stage"].to_s, session["outcome"].to_s,
              session["started_at"].to_s, session["session_id"] ]
          end,
          "groups" => grouped_sessions(sessions),
          "diagnostics" => diagnostics
        }
      end

      private

      def inventory_for(attempts)
        diagnostics = Array(@attempts_panel["diagnostics"]).map { |row| stringify(row) }
        inventory = {}
        attempts.each do |attempt|
          Array(attempt["sessions"]).each do |session|
            session_id = session["session_id"].to_s
            next if session_id.empty?

            binding = {
              session_id: session_id,
              attempt_id: attempt["attempt_id"].to_s,
              stage: attempt["stage"],
              outcome: session["outcome"] || attempt["outcome"] || attempt["state"],
              live: session["live"] == true,
              started_at: session["started_at"],
              usage: stringify(session["usage"] || {})
            }
            previous = inventory[session_id]
            if previous && previous.fetch(:attempt_id) != binding.fetch(:attempt_id)
              diagnostics << diagnostic(
                "session_bound_to_multiple_attempts", session_id: session_id
              )
              next
            end
            inventory[session_id] ||= binding
          end
        end
        [ inventory, diagnostics ]
      end

      def exact_usage(attempt)
        args = {
          attempt_id: attempt["attempt_id"],
          task_generation: attempt["task_generation"],
          project_slug: attempt["project_slug"],
          task_slug: attempt["task_slug"]
        }
        response = if @usage_reader.respond_to?(:exact_attempt)
          @usage_reader.exact_attempt(**args)
        else
          @usage_reader.call(**args)
        end
        symbolize(response)
      end

      def grouped_rows(rows)
        Array(rows).map { |row| symbolize(row) }
                   .reject { |row| row[:session_id].to_s.empty? }
                   .group_by { |row| row[:session_id].to_s }
                   .transform_values do |duplicates|
          duplicates.reduce(nil) { |current, row| richer_row(current, row) }
        end
      end

      def richer_row(left, right)
        return right unless left
        return left unless right

        richness = lambda do |row|
          %i[input output cache_read cache_write reasoning actual_backend actual_model
             billing_route billing_evidence_source].count { |key| !row[key].nil? }
        end
        [ left, right ].max_by { |row| [ richness.call(row), row[:ended_at].to_s ] }
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

      def unmetered_session(binding)
        {
          "session_id" => binding.fetch(:session_id),
          "attempt_id" => binding.fetch(:attempt_id),
          "stage" => binding.fetch(:stage),
          "outcome" => binding.fetch(:outcome),
          "live" => binding.fetch(:live),
          "started_at" => binding.fetch(:started_at),
          "ended_at" => nil, "harness" => nil, "actual_provider" => nil,
          "actual_model" => nil, "billing_route" => "unknown",
          "billing_evidence_source" => "unavailable",
          "input" => nil, "output" => nil, "cache_read" => nil,
          "cache_write" => nil, "reasoning" => nil,
          "api_equivalent" => {
            "coverage" => binding.fetch(:live) ? "pending" : "unavailable",
            "subtotal_usd" => nil, "observed_subtotal_usd" => nil,
            "missing_dimensions" => [ "usage" ], "rate_basis" => nil
          },
          "provider_reported_cost" => nil
        }
      end

      def aggregate_tokens(sessions)
        input = sessions.filter_map { |session| session["input"] }.sum
        output = sessions.filter_map { |session| session["output"] }.sum
        {
          "input" => input, "output" => output, "input_output" => input + output,
          "complete" => sessions.all? do |session|
            !session["input"].nil? && !session["output"].nil?
          end
        }
      end

      def aggregate_price(sessions, coverage)
        values = sessions.filter_map do |session|
          price = session.fetch("api_equivalent")
          price["subtotal_usd"] || price["observed_subtotal_usd"]
        end
        exact = values.reduce(BigDecimal("0"), :+)
        complete = coverage == "complete" && sessions.all? do |session|
          session.dig("api_equivalent", "coverage") == "complete"
        end
        {
          "coverage" => complete ? "complete" : coverage,
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
          "excluded_attributed_sessions_count" => 0,
          "unattributed_legacy_count" => nil,
          "tokens" => nil, "harnesses" => [], "actual_providers" => [],
          "actual_models" => [], "billing_routes" => [], "billing_route" => "unknown",
          "api_equivalent" => {
            "coverage" => "unavailable", "subtotal_usd" => nil,
            "observed_subtotal_usd" => nil, "priced_sessions_count" => 0,
            "unpriced_sessions_count" => 0,
            "missing_dimensions" => [ "attempt_inventory" ], "currency" => "USD"
          },
          "sessions" => [], "groups" => [], "diagnostics" => diagnostics
        }
      end

      def diagnostic(reason, **details)
        { "source" => "task_usage", "reason" => reason }.merge(
          details.reject { |_, value| value.nil? }.transform_keys(&:to_s)
        )
      end

      def truthy(value)
        value == true
      end

      def stringify(value)
        value.to_h.transform_keys(&:to_s)
      end

      def symbolize(value)
        value.to_h.transform_keys(&:to_sym)
      end
    end
  end
end
