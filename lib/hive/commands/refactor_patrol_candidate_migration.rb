require "json"
require "hive/refactor_patrol/installed_job_schema_migration"

module Hive
  module Commands
    # Candidate-only installation migration entrypoint used by every package
    # channel. The activation boundary itself fences a released daemon because
    # older package updaters did not necessarily do so.
    class RefactorPatrolCandidateMigration
      def initialize(output: $stdout, migration: nil)
        @output = output
        @migration = migration ||
          Hive::RefactorPatrol::InstalledJobSchemaMigration.new
      end

      # A failed/retryable project is a completed installation sweep: the
      # coordinator persists that row and retries it on a later sweep. Only
      # command/registry/status-store failures escape as structural errors.
      def call
        payload = @migration.call(force: true)
        @output.puts JSON.generate(payload)
        payload
      end
    end
  end
end
