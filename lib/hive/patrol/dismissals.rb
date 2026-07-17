require "time"
require "hive/gh"
require "hive/patrol/fingerprint"
require "hive/patrol/state_store"

module Hive
  module Patrol
    class Dismissals
      def initialize(project_root, state: StateStore.new(project_root), gh: Hive::Gh)
        @project_root = File.expand_path(project_root)
        @state = state
        @gh = gh
      end

      def reconcile(now: Time.now)
        fingerprints = @state.fingerprints
        dismissed = @state.dismissed
        fingerprints.each do |fingerprint, entry|
          branch = entry["branch"]
          next if branch.to_s.empty?

          prs = @gh.lookup_prs_for_branch(@project_root, branch)
          exact_pr = prs.find { |candidate| candidate["url"].to_s == entry["pr_url"].to_s }
          pr = if Fingerprint::RETRYABLE_PUBLICATION_STATES.include?(entry["state"])
                 exact_pr
          else
            exact_pr || prs.first
          end
          next unless pr

          case pr["state"]
          when "CLOSED"
            dismissed[fingerprint] = {
              "dismissed_at" => now.utc.iso8601,
              "pr_url" => pr["url"] || entry["pr_url"],
              "branch" => branch,
              # Carry the finding content forward so the similarity gate can
              # recognise a re-worded re-file of a dismissed issue.
              "category" => entry["category"],
              "feature_id" => entry["feature_id"],
              "title_tokens" => entry["title_tokens"],
              "root_cause_tokens" => entry["root_cause_tokens"]
            }.compact
            entry["state"] = "dismissed"
          when "MERGED"
            entry["state"] = "merged"
          when "OPEN"
            unless Fingerprint::RETRYABLE_PUBLICATION_STATES.include?(entry["state"])
              entry["state"] = "open"
            end
          end
        rescue Hive::GhError
          next
        end
        @state.write_fingerprints(fingerprints)
        @state.write_dismissed(dismissed)
        dismissed
      end
    end
  end
end
