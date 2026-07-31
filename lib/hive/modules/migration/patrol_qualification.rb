module Hive
  module Modules
    module Migration
      # Immutable, derived cutover-readiness value. It contains no path or
      # persistence authority; callers must resolve current bindings and
      # reconstruct it from verified evidence for every transition attempt.
      class PatrolQualification < Data.define(
        :status, :blockers, :run_id, :configuration_digests,
        :candidate, :scenario_manifest_digest, :verifications,
        :report_id
      )
        def ready_for_operator?
          status == "evidence_ready_for_operator"
        end

        private_class_method :new

        def self.build(**attributes)
          send(:new, **attributes).freeze
        end
      end
    end
  end
end
