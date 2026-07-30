require "json"
require "digest"
require "time"
require "hive/commands/module/base"
require "hive/config"
require "hive/modules/migration/migration_repository"
require "hive/modules/migration/patrols"
require "hive/modules/migration/report"
require "hive/modules/migration/report_migration"

module Hive
  module Commands
    class Module
      class Migration
        ACTIONS = %w[status report cutover rollback].freeze

        def initialize(action, project_root:, json:, stdout:, yes: false, reviewer: nil,
                       live_bindings_resolver: nil, **)
          @action = action.to_s
          @project_root = File.expand_path(project_root)
          @json = json
          @stdout = stdout
          @yes = yes
          @reviewer = reviewer
          @live_bindings_resolver = live_bindings_resolver
        end

        def call
          unless ACTIONS.include?(@action)
            raise UsageError, "module migration requires status, report, cutover, or rollback"
          end
          case @action
          when "status" then emit_state(read_state)
          when "report" then build_report
          when "cutover" then cutover
          when "rollback" then rollback
          end
        end

        private

        def build_report
          require_confirmation!("review shadow evidence")
          state = read_state
          raise Hive::ConfigError, "module migration is not shadowing" unless state.fetch("status") == "shadowing"
          reviewer = @reviewer.to_s.strip
          raise Hive::ConfigError, "module migration report requires --reviewer" if reviewer.empty?

          report = repository.with_lock do
            migration_result = migrate_report
            snapshot = repository.read_report_bytes(missing: true)
            expected_digest = if snapshot
              Digest::SHA256.hexdigest(snapshot)
            else
              Hive::Modules::Migration::MigrationRepository::EXPECTED_MISSING
            end
            replacement = with_live_bindings_resolver do |resolver|
              Hive::Modules::Migration::Report.build(
                lane_evidence: repository.incoming_bundles,
                reviewer: reviewer,
                reviewed_at: Time.now.utc,
                migration: migration_result.migration,
                live_bindings_resolver: resolver
              )
            end
            repository.write_report(
              replacement,
              expected_digest: expected_digest
            )
          end
          emit(report.payload, "Shadow report: #{report.status}")
        end

        def cutover
          require_confirmation!("cut over patrol mutator ownership")
          migrate_report
          report = migration.load_report_for_cutover
          outcome = migration.cutover!(report: report, now: Time.now.utc)
          emit_state(outcome.state)
        end

        def rollback
          require_confirmation!("roll back patrol mutator ownership")
          outcome = migration.rollback!(now: Time.now.utc)
          emit_state(outcome.state)
        end

        def require_confirmation!(action)
          raise ConsentRequired, "confirmation required; pass --yes to #{action}" unless @yes
        end

        def migration
          @migration ||= Hive::Modules::Migration::Patrols.new(
            project_root: @project_root, project: project_entry,
            hive_state_path: hive_state_path
          )
        end

        def read_state
          Hive::Modules::Migration::Patrols.read_state(
            @project_root, hive_state_path: hive_state_path
          ) || raise(Hive::ConfigError, "patrol module migration has not been adopted")
        end

        def report_path
          repository.report_path
        end

        def evidence_inbox
          File.join(
            File.dirname(report_path),
            "report-evidence",
            "incoming"
          )
        end

        def migrate_report
          Hive::Modules::Migration::ReportMigration.new(
            path: report_path,
            repository: repository
          ).ensure_current!
        end

        def repository
          @repository ||=
            Hive::Modules::Migration::MigrationRepository.for(
              project_root: @project_root,
              hive_state_path: hive_state_path
            )
        end

        def hive_state_path
          @hive_state_path ||= File.expand_path(Hive::Config.load(@project_root).fetch("hive_state_path"), @project_root)
        end

        def project_name
          entry = project_entry
          entry.is_a?(Hash) ?
            entry.fetch("name") :
            File.basename(@project_root)
        end

        def project_entry
          Hive::Config.registered_projects.find do |candidate|
            candidate.fetch("path") == @project_root
          end || File.basename(@project_root)
        end

        def with_live_bindings_resolver
          return yield @live_bindings_resolver if
            @live_bindings_resolver

          migration.with_live_bindings_resolver do |resolver|
            yield resolver
          end
        end

        def emit_state(state) = emit(state, "Patrol module migration: #{state.fetch('status')}")

        def emit(payload, human)
          @stdout.puts(@json ? JSON.generate(payload) : human)
          payload
        end
      end
    end
  end
end
