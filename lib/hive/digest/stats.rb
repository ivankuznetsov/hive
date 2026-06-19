require "logger"
require "hive/gh"

module Hive
  module Digest
    # Global footer totals for a day's digest: how many PRs shipped, and the
    # summed commit/line counts across them. `measured_prs` records how many
    # of those PRs we actually fetched stats for, so the renderer can omit
    # Lines/Commits when none could be measured (e.g. gh is unavailable) and
    # show a 0 only when it is a real zero.
    Totals = Data.define(:prs, :commits, :additions, :deletions, :measured_prs)

    # Aggregates per-PR `gh` stats for the footer. The fetch seam is injectable
    # so unit tests never hit the network; the default fetches via Hive::Gh.
    class Stats
      def initialize(fetch: nil, logger: Logger.new($stderr))
        @fetch = fetch || ->(pr_url) { Hive::Gh.pr_stats(pr_url) }
        @logger = logger
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
