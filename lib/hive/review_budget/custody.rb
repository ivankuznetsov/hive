require "hive/protected_files"

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
        @paths = @names.to_h { |name| ["reviews/#{name}", File.join(budget.reviews, name)] }
        @paths["review-budget/audit.jsonl"] = budget.audit_path
        @before = Hive::ProtectedFiles.observe_paths(@paths)
        @captured = Hive::ProtectedFiles.capture_paths(@paths)
      end

      def verify!
        exists = @budget.store.directory!(@budget.reviews, missing: true)
        current_names = exists ? Dir.children(@budget.reviews).select { |name| name.start_with?("review-grant-", "review-completion-") }.sort : []
        additions = current_names - @names
        paths = @paths.merge(additions.to_h { |name| ["reviews/#{name}", File.join(@budget.reviews, name)] })
        captured = @captured.merge(additions.to_h do |name|
          ["reviews/#{name}", { kind: :missing, fingerprint: nil, identity: { kind: :missing }.freeze }]
        end)
        changed = Hive::ProtectedFiles.diff(@before, Hive::ProtectedFiles.observe_paths(@paths))
        changed.concat(additions.map { |name| "reviews/#{name}" })
        return true if changed.empty? && ReviewBudget.digest(current_names) == @listing_digest

        paths.each_value { |path| @budget.store.directory!(File.dirname(path), missing: true) }
        Hive::ProtectedFiles.restore_paths(paths, captured, changed)
        unless ReviewBudget.digest(@budget.store.names) == @listing_digest
          raise Hive::ProtectedFiles::RestoreError, "review-budget receipt listing could not be restored"
        end
        raise Refused.new("agent_modified_budget", "agent modified protected review-budget evidence; original bytes were restored")
      rescue Hive::ProtectedFiles::RestoreError, SystemCallError => error
        raise Refused.new("unsafe_state", "review-budget custody restoration failed (#{error.class}); stop agent execution")
      end
    end
  end
end
