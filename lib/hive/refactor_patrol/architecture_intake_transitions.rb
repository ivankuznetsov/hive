require "digest"

module Hive
  module RefactorPatrol
    class ArchitectureIntakeTransitions
      def enqueue(entry:, store:, manifest:, policy:, now:, dry_run: false)
        store.enqueue_manifest!(
          manifest,
          policy: policy,
          occurrence_id: identity("occ", manifest),
          intake_transition_id: identity("intent", manifest),
          now: now,
          dry_run: dry_run
        )
      end

      private

      def identity(prefix, manifest)
        digest = Digest::SHA256.hexdigest(
          [ prefix, manifest.fetch("job_id"), manifest.fetch("manifest_checksum") ].join(":")
        )
        "#{prefix}-#{digest}"
      end
    end
  end
end
