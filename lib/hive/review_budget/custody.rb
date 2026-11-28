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
        @checkout_store = nil
        @checkout_custody = nil
        capture_internal_pr_checkout_custody!
      end

      def verify!
        budget_error = nil
        begin
          exists = @budget.store.directory!(@budget.reviews, missing: true)
          current_names = exists ? Dir.children(@budget.reviews).select { |name| name.start_with?("review-grant-", "review-completion-") }.sort : []
          additions = current_names - @names
          absent_paths = additions.to_h { |name| [ "reviews/#{name}", File.join(@budget.reviews, name) ] }
          (@paths.values + absent_paths.values).each { |path| @budget.store.directory!(File.dirname(path), missing: true) }
          changed = @custody.restore_changes!(absent_paths: absent_paths)
          unless changed.empty? && ReviewBudget.digest(current_names) == @listing_digest
            unless ReviewBudget.digest(@budget.store.names) == @listing_digest
              raise Hive::ArtifactFirewall::CaptureError, "review-budget receipt listing could not be restored"
            end
            budget_error = Refused.new("agent_modified_budget", "agent modified protected review-budget evidence; original bytes were restored")
          end
        rescue Hive::ArtifactFirewall::Error, SystemCallError => error
          budget_error = Refused.new("unsafe_state", "review-budget custody restoration failed (#{error.class}); stop agent execution")
        end

        checkout_error = verify_internal_pr_checkout_custody
        raise checkout_error if checkout_error
        raise budget_error if budget_error

        true
      end

      private

      def capture_internal_pr_checkout_custody!
        require "hive/internal_pr_checkout/identity"
        require "hive/internal_pr_checkout/store"
        store = Hive::InternalPrCheckout::Store.new(@budget.folder)
        applicable = Hive::InternalPrCheckout::Identity.applicable?(@budget.task, allow_any_stage: true) ||
                     File.exist?(store.store_dir) || File.symlink?(store.store_dir)
        return unless applicable

        @checkout_store = store
        @checkout_custody = store.capture_custody
      rescue Hive::InternalPrCheckout::CustodyError => error
        reason = error.reason == "custody_limit_exceeded" ? "evidence_limit" : "unsafe_state"
        raise Refused.new(reason, error.message)
      end

      def verify_internal_pr_checkout_custody
        return nil unless @checkout_store && @checkout_custody

        @checkout_store.verify_custody!(@checkout_custody)
        nil
      rescue Hive::InternalPrCheckout::CustodyError => error
        reason = if error.reason == "custody_limit_exceeded"
          "evidence_limit"
        elsif error.message.include?("original bytes were restored")
          "agent_modified_budget"
        else
          "unsafe_state"
        end
        Refused.new(reason, error.message)
      rescue Hive::ArtifactFirewall::Error, SystemCallError => error
        Refused.new("unsafe_state", "internal PR checkout custody verification failed (#{error.class}); stop agent execution")
      end
    end
  end
end
