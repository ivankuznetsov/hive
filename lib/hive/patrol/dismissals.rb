require "time"
require "hive/gh"
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
          pr = prs.find { |candidate| candidate["url"].to_s == entry["pr_url"].to_s } || prs.first
          next unless pr

          case pr["state"]
          when "CLOSED"
            dismissed[fingerprint] = {
              "dismissed_at" => now.utc.iso8601,
              "pr_url" => pr["url"] || entry["pr_url"],
              "branch" => branch
            }
            entry["state"] = "dismissed"
          when "MERGED"
            entry["state"] = "merged"
          when "OPEN"
            entry["state"] = "open"
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
