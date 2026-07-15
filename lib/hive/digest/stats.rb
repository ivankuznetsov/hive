require "logger"
require "hive/gh"

module Hive
  module Digest
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

      # Sum stats across every PR-bearing item that has a PR URL. A per-PR fetch
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

      def fetch_stats(url)
        @fetch.call(url)
      rescue Hive::Error => e
        @logger&.warn("digest stats: dropping #{url}: #{e.message}")
        nil
      end
    end
  end
end
