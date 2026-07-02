require "logger"
require "time"
require "hive/gh"
require "hive/digest/window"
require "hive/digest/merged_pr/record"
require "hive/digest/merged_pr/hive_matcher"

module Hive
  module Digest
    module MergedPr
      class Collector
        attr_reader :warnings

        def initialize(gh: Hive::Gh, matcher: HiveMatcher.new, cfg: nil, logger: Logger.new($stderr))
          @gh = gh
          @matcher = matcher
          @cfg = cfg
          @logger = logger
          @warnings = []
        end

        def for_date(date, repos:)
          @warnings = []
          collected = Array(repos).flat_map do |repo|
            collect_repo(repo, date)
          rescue StandardError => e
            warn("merged-pr digest: dropping repo #{repo}: #{e.message}")
            []
          end
          # Order the machine-readable prs[] deterministically (plan U4: by repo
          # then chronologically by mergedAt). The renderer re-sorts each repo's
          # rows for display, but the JSON array carries this order verbatim.
          collected.sort_by { |pr| [ pr.repo, Window.parse_time(pr.mergedAt) ] }
        end

        private

        def collect_repo(repo, date)
          candidates = @gh.list_merged_prs(
            repo,
            since: (date - 1).iso8601,
            until_date: (date + 1).iso8601,
            cfg: @cfg
          )
          # No per-repo sort here: for_date sorts the whole collection once (by
          # repo then mergedAt) and the renderer re-sorts each repo's rows for
          # display, so sorting the single repo's candidates too would be dead
          # work.
          candidates.filter_map { |doc| build_pr(repo, doc, date) }
        end

        def build_pr(repo, doc, date)
          merged_at = doc.fetch("mergedAt").to_s
          return nil unless Window.on_local_date?(merged_at, date)

          # Like mergedAt, fetch the number so a missing key drops the record
          # (schema requires number >= 1); Integer() drops a blank/unexpected
          # value via the ArgumentError rescue instead of coercing it to 0. A
          # non-positive number would violate the schema's minimum:1, so raise
          # to drop it via the same rescue rather than emit an out-of-spec row.
          number = Integer(doc.fetch("number").to_s)
          raise ArgumentError, "PR number must be positive, got #{number}" unless number.positive?
          head_ref = doc["headRefName"].to_s
          match = match_hive(head_ref)
          author = doc["author"].is_a?(Hash) ? doc["author"] : {}
          PullRequest.new(
            repo: repo,
            number: number,
            title: doc["title"].to_s,
            url: doc["url"].to_s,
            mergedAt: merged_at,
            author: author["login"].to_s,
            authorIsBot: author["is_bot"] == true,
            headRefName: head_ref,
            isCrossRepository: doc["isCrossRepository"] == true,
            hive_slug: match&.fetch(:slug, nil),
            hive_stage: match&.fetch(:stage, nil)
          )
        rescue KeyError, ArgumentError => e
          warn("merged-pr digest: dropping malformed PR in #{repo}: #{e.message}")
          nil
        end

        def match_hive(head_ref)
          @matcher.match(head_ref)
        rescue StandardError => e
          warn("merged-pr digest: Hive match skipped for #{head_ref}: #{e.message}")
          nil
        end

        def warn(message)
          @warnings << message
          @logger&.warn(message)
        end
      end
    end
  end
end
