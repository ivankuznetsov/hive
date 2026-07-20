require "hive/digest/repository"

module Hive
  module Digest
    MetricTotal = Data.define(:value, :known_count, :contributor_count) do
      def initialize(value:, known_count:, contributor_count:)
        known = Integer(known_count)
        contributors = Integer(contributor_count)
        unless contributors >= 0 && known.between?(0, contributors)
          raise ArgumentError, "digest metric coverage must be within contributor count"
        end
        unless value.nil? || (value.is_a?(Integer) && !value.negative?)
          raise ArgumentError, "digest metric total must be nil or a non-negative Integer"
        end
        if known.zero? != value.nil?
          raise ArgumentError, "digest metric total must be nil exactly when no values are known"
        end

        super(value: value, known_count: known, contributor_count: contributors)
      end

      def partial? = known_count.positive? && known_count < contributor_count
      def unavailable? = known_count.zero? && contributor_count.positive?
      def complete? = known_count == contributor_count
    end

    Aggregate = Data.define(:pr_count, :metrics) do
      def initialize(pr_count:, metrics:)
        count = Integer(pr_count)
        raise ArgumentError, "digest PR count must not be negative" if count.negative?

        super(pr_count: count, metrics: metrics.transform_keys(&:to_sym).freeze)
      end

      def metric(name) = metrics.fetch(name.to_sym)
    end

    StatsReport = Data.define(:overall, :by_repository, :warnings)

    class Stats
      def for_repositories(repositories)
        rows = Array(repositories)
        by_repository = rows.to_h do |repository|
          [ repository.target.repository, aggregate(repository.pull_requests) ]
        end
        pull_requests = rows.flat_map(&:pull_requests)
        warnings = pull_requests.filter_map do |pr|
          missing = PR_METRICS.select { |metric| pr.public_send(metric).nil? }
          next if missing.empty?

          Warning.new(
            kind: "statistics_incomplete",
            repository: pr.repository,
            pr_number: pr.number,
            metrics: missing,
            message: "Statistics unavailable for #{pr.repository}##{pr.number}: #{missing.join(', ')}"
          )
        end
        StatsReport.new(
          overall: aggregate(pull_requests),
          by_repository: by_repository.freeze,
          warnings: warnings.freeze
        )
      end

      private

      def aggregate(pull_requests)
        rows = Array(pull_requests)
        metrics = PR_METRICS.to_h do |metric|
          values = rows.filter_map { |pr| pr.public_send(metric) }
          [
            metric,
            MetricTotal.new(
              value: values.empty? ? nil : values.sum,
              known_count: values.size,
              contributor_count: rows.size
            )
          ]
        end
        Aggregate.new(pr_count: rows.size, metrics: metrics)
      end
    end
  end
end
