require "hive/artifact_firewall"

module Hive
  class ReviewBudget
    # A process-local custody snapshot protects explicit paths, including an
    # absent audit. The separate listing closes the unbounded-name addition
    # hole; directory fingerprints alone would not protect their children.
    class Custody
      def initialize(budget)
        @budget = budget
        @names = budget.store.names
        @listing_digest = ReviewBudget.digest(@names)
        @paths = @names.to_h { |name| [ "reviews/#{name}", File.join(budget.reviews, name) ] }
        @paths["review-budget/audit.jsonl"] = budget.audit_path
        @custody = Hive::ArtifactFirewall::PathCustody.new(@paths)
      end

      def verify!
        exists = @budget.store.directory!(@budget.reviews, missing: true)
        current_names = exists ? Dir.children(@budget.reviews).select { |name| name.start_with?("review-grant-", "review-completion-") }.sort : []
        additions = current_names - @names
        absent_paths = additions.to_h { |name| [ "reviews/#{name}", File.join(@budget.reviews, name) ] }
        (@paths.values + absent_paths.values).each { |path| @budget.store.directory!(File.dirname(path), missing: true) }
        changed = @custody.restore_changes!(absent_paths: absent_paths)
        return true if changed.empty? && ReviewBudget.digest(current_names) == @listing_digest

        unless ReviewBudget.digest(@budget.store.names) == @listing_digest
          raise Hive::ArtifactFirewall::CaptureError, "review-budget receipt listing could not be restored"
        end
        raise Refused.new("agent_modified_budget", "agent modified protected review-budget evidence; original bytes were restored")
      rescue Hive::ArtifactFirewall::Error, SystemCallError => error
        raise Refused.new("unsafe_state", "review-budget custody restoration failed (#{error.class}); stop agent execution")
      end
    end
  end
end
