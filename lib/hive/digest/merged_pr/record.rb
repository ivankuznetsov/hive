module Hive
  module Digest
    module MergedPr
      PullRequest = Data.define(
        :repo,
        :number,
        :title,
        :url,
        :mergedAt,
        :author,
        :authorIsBot,
        :headRefName,
        :isCrossRepository,
        :hive_slug,
        :hive_stage
      ) do
        # Hive::Digest::Stats consumes any PR-bearing record through pr_url.
        # Keep the merged JSON field named `url` while satisfying that shared
        # aggregation contract without a parallel stats implementation.
        def pr_url = url

        def to_h
          {
            "repo" => repo,
            "number" => number,
            "title" => title,
            "url" => url,
            "mergedAt" => mergedAt,
            "author" => author,
            "authorIsBot" => authorIsBot,
            "headRefName" => headRefName,
            "isCrossRepository" => isCrossRepository,
            "hive_slug" => hive_slug,
            "hive_stage" => hive_stage
          }.compact
        end
      end

      Resolution = Data.define(:repos, :warnings)
    end
  end
end
