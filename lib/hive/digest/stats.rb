require "logger"
require "hive/gh"
require "hive/digest/repository"

module Hive
  module Digest
    MetricTotal = Data.define(:value, :known_count, :contributor_count) do
      def initialize(value:, known_count:, contributor_count:)
        known = Integer(known_count)
        contributors = Integer(contributor_count)
        unless known.between?(0, contributors) && contributors >= 0
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

    # Global footer totals for a day's digest: how many PRs shipped, and the
    # summed commit/line counts across them. `measured_prs` records how many
    # of those PRs we actually fetched stats for, so the renderer can omit
    # Lines/Commits when none could be measured (e.g. gh is unavailable) and
    # show a 0 only when it is a real zero.
    Totals = Data.define(:prs, :commits, :additions, :deletions, :measured_prs) do
      # Guard the counts at the boundary (mirroring the module's other Data
      # types) so the renderer's `measured_prs`-sentinel logic can trust them:
      # all counts are non-negative integers, and you can't measure more PRs
      # than shipped. A violation would make the footer hide real numbers or
      # show a misleading `+0/-0`, so make it structural rather than incidental.
      def initialize(prs:, commits:, additions:, deletions:, measured_prs:)
        { prs: prs, commits: commits, additions: additions,
          deletions: deletions, measured_prs: measured_prs }.each do |field, value|
          unless value.is_a?(Integer) && value >= 0
            raise ArgumentError, "Totals #{field} must be a non-negative Integer; got #{value.inspect}"
          end
        end
        if measured_prs > prs
          raise ArgumentError, "Totals measured_prs (#{measured_prs}) cannot exceed prs (#{prs})"
        end

        super
      end
    end

    # Aggregates per-PR `gh` stats for the footer. The fetch seam is injectable
    # so unit tests never hit the network; the default fetches via Hive::Gh.
    class Stats
      def initialize(fetch: nil, logger: Logger.new($stderr))
        @fetch = fetch || ->(pr_url) { Hive::Gh.pr_stats(pr_url) }
        @logger = logger
      end

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

      # Sum stats across every shipped item that has a PR URL. A per-PR fetch
      # failure is logged and skipped (it still counts toward `prs`, just not
      # toward the measured sums) so one gone/private PR never fails the digest.
      def for_items(items)
        prs = 0
        commits = 0
        additions = 0
        deletions = 0
        measured = 0

        Array(items).each do |item|
          url = item.pr_url.to_s
          next if url.strip.empty?

          prs += 1
          stats = fetch_stats(url)
          next unless stats

          additions += stats[:additions].to_i
          deletions += stats[:deletions].to_i
          commits += stats[:commits].to_i
          measured += 1
        end

        # A single dropped PR is a per-PR `warn` above, but a whole-digest stats
        # blackout (gh missing / auth expired / network down) would otherwise
        # surface only as N indistinguishable warnings while the footer silently
        # drops Lines/Commits. Emit ONE aggregate error so a systemic outage is
        # loud and distinct from a legitimately quiet day.
        if prs.positive? && measured.zero?
          @logger&.error("digest stats: measured 0/#{prs} PRs — gh stats unavailable for the whole digest")
        end

        Totals.new(prs: prs, commits: commits, additions: additions,
                   deletions: deletions, measured_prs: measured)
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

      def fetch_stats(url)
        @fetch.call(url)
      rescue Hive::Error => e
        @logger&.warn("digest stats: dropping #{url}: #{e.message}")
        nil
      end
    end
  end
end
