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
