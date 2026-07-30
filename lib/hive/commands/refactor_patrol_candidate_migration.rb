require "json"
require "hive/refactor_patrol/installed_job_schema_migration"
require "hive/refactor_patrol/installed_users_job_schema_migration"
require "hive/refactor_patrol/all_users_authority"
require "hive/refactor_patrol/install_wide_retry_service"

module Hive
  module Commands
    # Candidate-only migration entrypoint used by package channels. Its
    # privileged form coordinates every known user profile; its child/current
    # form owns one profile and fences that user's released daemon.
    class RefactorPatrolCandidateMigration
      def initialize(output: $stdout, migration: nil, all_users: false,
                     all_users_migration: nil, all_users_authority: nil,
                     ensure_retry_service: false,
                     retry_service_installer: nil, force: true)
        @output = output
        @migration = migration ||
          Hive::RefactorPatrol::InstalledJobSchemaMigration.new
        @all_users = all_users
        @force = force
        @ensure_retry_service = ensure_retry_service == true
        @all_users_migration = all_users_migration
        @all_users_authority = all_users_authority ||
          Hive::RefactorPatrol::AllUsersAuthority.new
        @retry_service_installer = retry_service_installer ||
          Hive::RefactorPatrol::InstallWideRetryService.new
      end

      # A failed/retryable project is a completed user-profile sweep: the
      # coordinator persists that row and retries it on a later sweep. Only
      # command/registry/status-store failures escape as structural errors.
      def call
        if @ensure_retry_service && !@all_users
          raise Hive::ConfigError,
                "--ensure-retry-service requires --all-users"
        end
        payload =
          if @all_users
            candidate = nil
            if @all_users_migration.nil? || @ensure_retry_service
              candidate = @all_users_authority.authorize!
            end
            @retry_service_installer.ensure!(candidate: candidate) if
              @ensure_retry_service
            migration = @all_users_migration ||
              Hive::RefactorPatrol::InstalledUsersJobSchemaMigration.new(
                candidate: candidate
              )
            migration.call(force: @force)
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
