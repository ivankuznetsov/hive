require "json"
require "hive/gh"
require "hive/task_journal"
require "hive/task_projection"

module Hive
  # Latest GitHub outcome Hive has durably observed for a task's current pull
  # request. The daemon PR merge watcher and the publication cache both record
  # PR outcomes as `pr_observed` / `merge_observed` task-journal activity
  # ("pull request outcome changed"); this reader replays those records and
  # never calls GitHub, so it is cheap enough to fence review admission.
  #
  # Fail-safe: a missing pr.md, an unparseable PR URL, an unreadable journal,
  # or no observation for the current PR all yield nil, and callers keep their
  # pre-existing behavior.
  module PullRequestOutcome
    MERGED = "merged".freeze
    CLOSED_UNMERGED = "closed_unmerged".freeze
    OPEN = "open".freeze

    OBSERVATION_KINDS = %w[pr_observed merge_observed].freeze

    # Watcher states (open / merged / closed_unmerged / ambiguous /
    # delivered_elsewhere) and publication-cache states (open / merged /
    # closed). `ambiguous` and `delivered_elsewhere` are MERGED on GitHub; the
    # watcher only refuses to auto-archive them without operator evidence.
    STATES = {
      "open" => OPEN,
      "merged" => MERGED,
      "ambiguous" => MERGED,
      "delivered_elsewhere" => MERGED,
      "closed_unmerged" => CLOSED_UNMERGED,
      "closed" => CLOSED_UNMERGED
    }.freeze

    Observation = Data.define(:state, :pr_url) do
      def merged? = state == MERGED
      def closed_unmerged? = state == CLOSED_UNMERGED
      # A merged or closed PR must not receive further review agent work.
      def settled? = merged? || closed_unmerged?
    end

    module_function

    # @param task_folder [String]
    # @return [Observation, nil]
    def latest(task_folder)
      folder = task_folder.to_s
      pr_url = canonical_url(Hive::Gh.pr_frontmatter(File.join(folder, "pr.md"))["pr_url"])
      return nil unless pr_url

      records = Hive::TaskProjection.read_journal(
        File.join(folder, Hive::TaskJournal::JOURNAL_BASENAME)
      )
      state = records.reverse_each.lazy.filter_map { |record| state_for(record, pr_url) }.first
      state && Observation.new(state: state, pr_url: pr_url)
    rescue Hive::Error, JSON::ParserError, SystemCallError, IOError, ArgumentError, TypeError
      nil
    end

    # Scoped observation lookup for internal PR reviews (U6.2): requires exact
    # PR URL and head OID match (plus matching generation when recorded and an
    # observation timestamp at or after `after:` when supplied). Older URL-only
    # entries from a prior head are ignored so reopening the same URL at a new
    # head is never falsely stopped by an older closed-PR observation.
    def latest_for_generation(task_folder, pr_url:, head_oid:, generation: nil, after: nil)
      folder = task_folder.to_s
      canonical = canonical_url(pr_url)
      target_oid = head_oid.to_s.downcase
      return nil unless canonical && target_oid.match?(/\A[0-9a-f]{40,64}\z/)

      after_time = parse_time(after)
      records = Hive::TaskProjection.read_journal(
        File.join(folder, Hive::TaskJournal::JOURNAL_BASENAME)
      )
      state = records.reverse_each.lazy.filter_map do |record|
        scoped_state_for(
          record,
          pr_url: canonical,
          head_oid: target_oid,
          generation: generation,
          after_time: after_time
        )
      end.first
      state && Observation.new(state: state, pr_url: canonical)
    rescue Hive::Error, JSON::ParserError, SystemCallError, IOError, ArgumentError, TypeError
      nil
    end

    def scoped_state_for(record, pr_url:, head_oid:, generation:, after_time:)
      payload = record["payload"]
      return nil unless payload.is_a?(Hash) &&
                        OBSERVATION_KINDS.include?(payload["activity_kind"]) &&
                        canonical_url(payload["pr_url"]) == pr_url

      recorded_oid = payload["head_oid"].to_s.downcase
      return nil unless recorded_oid == head_oid

      if generation && payload.key?("generation") && !payload["generation"].nil?
        return nil unless payload["generation"].to_i == generation.to_i
      end

      if after_time
        observed_at = parse_time(record["observed_at"] || record["occurred_at"] || payload["observed_at"])
        return nil if observed_at && observed_at < after_time
      end

      STATES[payload["merge_state"].to_s.downcase] || STATES[payload["pr_state"].to_s.downcase]
    end

    def parse_time(value)
      return nil if value.nil? || value.to_s.empty?
      return value.utc if value.respond_to?(:utc)

      Time.iso8601(value.to_s).utc
    rescue ArgumentError
      nil
    end

    def state_for(record, pr_url)
      payload = record["payload"]
      return nil unless payload.is_a?(Hash) &&
                        OBSERVATION_KINDS.include?(payload["activity_kind"]) &&
                        canonical_url(payload["pr_url"]) == pr_url

      STATES[payload["merge_state"].to_s] || STATES[payload["pr_state"].to_s]
    end

    def canonical_url(value)
      Hive::Gh.parse_pull_request_url(value.to_s)&.fetch("url")
    end
  end
end
