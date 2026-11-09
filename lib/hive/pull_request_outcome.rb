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
