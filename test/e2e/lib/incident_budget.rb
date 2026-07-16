module Hive
  module E2E
    class IncidentBudget
      DEFAULT_PER_SCENARIO_SECONDS = 5.0
      DEFAULT_AGGREGATE_SECONDS = 30.0
      INCIDENT_TAG = "incident-regression"

      Result = Data.define(:durations, :total_seconds, :violations) do
        def ok?
          violations.empty?
        end
      end

      def self.check(report, per_scenario_limit: DEFAULT_PER_SCENARIO_SECONDS,
                     aggregate_limit: DEFAULT_AGGREGATE_SECONDS)
        new(report, per_scenario_limit: per_scenario_limit,
                    aggregate_limit: aggregate_limit).check
      end

      def initialize(report, per_scenario_limit:, aggregate_limit:)
        @report = report
        @per_scenario_limit = Float(per_scenario_limit)
        @aggregate_limit = Float(aggregate_limit)
      end

      def check
        results_by_name = Array(@report["scenarios"]).to_h { |result| [ result["name"], result ] }
        durations = {}
        violations = []

        enabled_incidents.each do |metadata|
          name = metadata["name"]
          result = results_by_name[name]
          unless result
            violations << "enabled incident #{name.inspect} has no scenario result"
            next
          end

          duration = Float(result["duration_seconds"])
          durations[name] = duration
          if duration >= @per_scenario_limit
            violations << format(
              "%s took %.3fs (must be below %.3fs)",
              name, duration, @per_scenario_limit
            )
          end
        rescue ArgumentError, TypeError
          violations << "enabled incident #{name.inspect} has an invalid duration"
        end

        total = durations.values.sum
        if total >= @aggregate_limit
          violations << format(
            "incident group took %.3fs (must be below %.3fs)",
            total, @aggregate_limit
          )
        end

        Result.new(durations: durations.freeze, total_seconds: total, violations: violations.freeze)
      end

      private

      def enabled_incidents
        Array(@report["scenario_metadata"]).select do |metadata|
          Array(metadata["tags"]).include?(INCIDENT_TAG) && metadata["pending"] == false
        end
      end
    end
  end
end
