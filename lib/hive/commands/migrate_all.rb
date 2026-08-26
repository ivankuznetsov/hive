require "shellwords"
require "hive/config"
require "hive/commands/migrate"
require "hive/invoked_binary"
require "hive/recovery/migration"

module Hive
  module Commands
    class MigrateAll
      Failure = Data.define(:name, :path, :message, :kind)
      SKIP_GLOBAL_MIGRATION = -> { }.freeze

      def initialize(projects: nil, output: $stdout, error_output: $stderr,
                     command_factory: nil,
                     global_migration: Hive::Recovery::Migration.method(:ensure!),
                     daemon_restarter: Hive::Commands::Migrate.method(:restart_daemon_if_running!),
                     daemon_cutover: Hive::Commands::Migrate.method(:restart_daemon_for_patrol_index_cutover!),
                     binary: nil, env: ENV)
        @projects = projects
        @output = output
        @error_output = error_output
        @command_factory = command_factory || method(:project_migration)
        @global_migration = global_migration
        @daemon_restarter = daemon_restarter
        @daemon_cutover = daemon_cutover
        @binary = binary || resolve_binary(env)
        @daemon_restart_required = false
        @daemon_cutover_completed = false
      end

      def call
        migrate_global_state!
        projects = @projects || Hive::Config.registered_projects
        if projects.empty?
          @output.puts "hive: migration: no registered projects; global state is current"
          return 0
        end

        @output.puts "hive: migration: checking #{projects.size} registered projects"
        failures = []
        projects.each_with_index do |project, index|
          name = project.fetch("name")
          path = project.fetch("path")
          @output.puts "hive: migration: [#{index + 1}/#{projects.size}] #{name} (#{path})"
          begin
            @command_factory.call(path).call
            @output.puts "hive: migration: ok #{name}"
          rescue StandardError => error
            failure = build_failure(name, path, error)
            failures << failure
            report_failure(failure)
          end
        end

        migrated = projects.size - failures.size
        if failures.empty?
          # A successful fleet migration is also the update cutover point.
          # Restart once even when this retry did not rewrite anything: an
          # earlier partial fleet pass may already have committed a config
          # migration and deferred its restart. The restarter is idempotent
          # when no daemon is running.
          restart_daemon_after_successful_fleet!
          @output.puts "hive: migration: complete (#{project_count(migrated)} migrated, 0 failed)"
          return 0
        end

        if @daemon_restart_required
          @error_output.puts(
            "hive: migration: daemon restart deferred until every registered project migrates successfully"
          )
        end

        @error_output.puts(
          "hive: migration: incomplete (#{project_count(migrated)} migrated, " \
          "#{project_count(failures.size)} failed)"
        )
        raise Hive::Error,
              "migration incomplete: #{failures.size} of #{projects.size} registered projects failed; " \
              "fix the errors above and run `#{migrate_all_command}`"
      end

      private

      def project_migration(path)
        Hive::Commands::Migrate.new(
          path,
          global_migration: SKIP_GLOBAL_MIGRATION,
          daemon_restarter: method(:request_daemon_restart),
          daemon_cutover: method(:cutover_daemon_now)
        )
      end

      def migrate_global_state!
        @output.puts "hive: migration: checking global state"
        @global_migration.call
      rescue StandardError => error
        message = readable_error(error)
        @error_output.puts "hive: migration: global state failed: #{message}"
        @error_output.puts "hive: migration: recovery: #{migrate_all_command}"
        raise Hive::Error,
              "global migration failed: #{message}; fix the error above and run `#{migrate_all_command}`"
      end

      def report_failure(failure)
        @error_output.puts "hive: migration: failed for #{failure.name}: #{failure.message}"
        if failure.kind == :missing_project
          project_command = Shellwords.join([ @binary, "migrate", failure.path ])
          forget_command = Shellwords.join([ @binary, "forget", failure.name ])
          prune_command = Shellwords.join([ @binary, "prune" ])
          @error_output.puts "hive: migration: recovery: restore #{failure.path}, then run #{project_command}"
          @error_output.puts "hive: migration: recovery: or remove the stale registration with #{forget_command}"
          @error_output.puts "hive: migration: recovery: remove all stale registrations with #{prune_command}"
          return
        end

        command = Shellwords.join([ @binary, "migrate", failure.path ])
        @error_output.puts "hive: migration: recovery: #{command}"
      end

      def build_failure(name, path, error)
        missing_project = error.is_a?(Hive::InvalidTaskPath) &&
                          !Dir.exist?(File.join(path, ".hive-state", "stages"))
        message = if missing_project
          "registered path is missing or no longer contains a Hive project (#{path})"
        else
          readable_error(error)
        end
        Failure.new(
          name: name,
          path: path,
          message: message,
          kind: missing_project ? :missing_project : :migration
        )
      end

      def request_daemon_restart
        @daemon_restart_required = true
      end

      def cutover_daemon_now
        return true if @daemon_cutover_completed

        restarted = @daemon_cutover.call
        @daemon_cutover_completed ||= restarted
        restarted
      end

      def restart_daemon_after_successful_fleet!
        return if @daemon_cutover_completed && !@daemon_restart_required

        @daemon_restarter.call
      end

      def migrate_all_command
        Shellwords.join([ @binary, "migrate", "--all" ])
      end

      def resolve_binary(env)
        Hive::InvokedBinary.path(env: env) ||
          Hive::InvokedBinary.which("hive", env: env) ||
          Hive::InvokedBinary.which("hv", env: env) ||
          "hive"
      end

      def readable_error(error)
        message = error.message.to_s.gsub(/\s+/, " ").strip
        message.empty? ? error.class.name : message
      end

      def project_count(count)
        "#{count} project#{count == 1 ? '' : 's'}"
      end
    end
  end
end
