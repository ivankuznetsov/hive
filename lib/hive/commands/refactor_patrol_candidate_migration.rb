require "json"
require "hive/refactor_patrol/installed_job_schema_migration"
require "hive/refactor_patrol/installed_users_job_schema_migration"

module Hive
  module Commands
    # Candidate-only migration entrypoint used by package channels. Its
    # privileged form coordinates every known user profile; its child/current
    # form owns one profile and fences that user's released daemon.
    class RefactorPatrolCandidateMigration
      def initialize(output: $stdout, migration: nil, all_users: false,
                     all_users_migration: nil, force: true)
        @output = output
        @migration = migration ||
          Hive::RefactorPatrol::InstalledJobSchemaMigration.new
        @all_users = all_users
        @force = force
        @all_users_migration = all_users_migration ||
          Hive::RefactorPatrol::InstalledUsersJobSchemaMigration.new
      end

      # A failed/retryable project is a completed user-profile sweep: the
      # coordinator persists that row and retries it on a later sweep. Only
      # command/registry/status-store failures escape as structural errors.
      def call
        payload =
          if @all_users
            @all_users_migration.call(force: @force)
          else
            @migration.call(force: @force)
          end
        @output.puts JSON.generate(payload)
        if @all_users && payload["status"] != "complete"
          raise Hive::Error,
                "install-wide JobStore migration is #{payload['status']}; " \
                "inspect the emitted receipt and retry after remediation"
        end

        payload
      end
    end
  end
end
