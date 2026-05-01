module Hive
  module E2E
    # Single source of truth for the e2e binary's structured-output schema
    # names + versions. Producers (runner.rb, artifact_capture.rb,
    # bin/hive-e2e) reference these constants when emitting JSON, and a
    # drift test in test/e2e/lib/schemas_test.rb walks every producer to
    # verify every emitted name is registered here.
    #
    # Adding a new schema means: (a) add the constant here, (b) reference
    # it at the producer site, (c) the drift test will catch a typo or a
    # producer using a name that isn't registered.
    #
    # Versioning contract: bumping a value here is a breaking-change
    # marker for downstream agent consumers (e.g., manifests parsed by
    # external tooling). Adding a key without bumping is additive.
    module Schemas
      VERSIONS = {
        "hive-e2e-error"        => 1,
        "hive-e2e-scenarios"    => 1,
        "hive-e2e-clean"        => 1,
        "hive-e2e-report"       => 1,
        "hive-e2e-env-snapshot" => 1,
        "hive-e2e-manifest"     => 1
      }.freeze

      # Look up a schema's version by name. Raises if the name is not
      # registered, so producers cannot silently emit unknown schemas.
      def self.version_for(name)
        VERSIONS.fetch(name) do
          raise KeyError, "unknown e2e schema #{name.inspect} — register it in test/e2e/lib/schemas.rb"
        end
      end
    end
  end
end
