require "time"
require "json"
require "hive/gh"
require "hive/patrol/fingerprint"
require "hive/patrol/state_store"

module Hive
  module Patrol
    class Dismissals
      def initialize(project_root, state:, gh: Hive::Gh, persist: true)
        @project_root = File.expand_path(project_root)
        @state = state
        @gh = gh
        @persist = persist == true
      end

      def reconcile(now: Time.now)
        @state.configured_effect_gateway! if @persist
        fingerprints = @state.fingerprints
        dismissed = @state.dismissed
        changed = {}
        fingerprints.each do |fingerprint, entry|
          before = JSON.generate(entry)
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
              "target_sha" => entry["target_sha"],
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
          changed[fingerprint] = entry if JSON.generate(entry) != before
        rescue Hive::GhError
          next
        end
        if @persist
          changed.each do |fingerprint, entry|
            @state.mutate_fingerprints!(
              fingerprint: fingerprint,
              idempotency_key:
                "dismissal-reconcile:#{fingerprint}:#{entry['state']}",
              scope: { "fingerprint" => fingerprint },
              set: entry,
              deleted: [],
              replace: true
            )
          end
          @state.write_dismissed(dismissed)
        end
        dismissed
      end
    end
  end
end
