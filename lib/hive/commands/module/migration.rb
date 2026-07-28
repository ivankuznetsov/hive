require "json"
require "time"
require "hive/config"
require "hive/modules/migration/patrols"
require "hive/modules/migration/report"
require "hive/modules/migration/shadow_comparator"
require "hive/modules/migration/shadow_decision_migration"

module Hive
  module Commands
    class Module
      class Migration
        ACTIONS = %w[status report cutover rollback].freeze

        def initialize(action, project_root:, json:, stdout:, yes: false, reviewer: nil, **)
          @action = action.to_s
          @project_root = File.expand_path(project_root)
          @json = json
          @stdout = stdout
          @yes = yes
          @reviewer = reviewer
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

          records = comparator.records.select do |record|
            Time.iso8601(record.fetch("recorded_at")) >= Time.iso8601(state.fetch("shadow_started_at"))
          end
          report = Hive::Modules::Migration::Report.build(
            records: records, reviewer: reviewer, reviewed_at: Time.now.utc
          )
          report.write(report_path)
          emit(report.payload, "Shadow report: #{report.eligible? ? 'eligible' : 'blocked'}")
        end

        def cutover
          require_confirmation!("cut over patrol mutator ownership")
          report = Hive::Modules::Migration::Report.load(report_path)
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
            project_root: @project_root, project: project_name,
            hive_state_path: hive_state_path
          )
        end

        def comparator
          Hive::Modules::Migration::ShadowDecisionMigration.ensure_complete!(
            root: shadow_root
          )
          Hive::Modules::Migration::ShadowComparator.new(
            root: shadow_root
          )
        end

        def shadow_root
          File.join(hive_state_path, "module-runtime", "migration", "shadow")
        end

        def read_state
          Hive::Modules::Migration::Patrols.read_state(
            @project_root, hive_state_path: hive_state_path
          ) || raise(Hive::ConfigError, "patrol module migration has not been adopted")
        end

        def report_path
          Hive::Modules::Migration::Patrols.report_file(
            @project_root, hive_state_path: hive_state_path
          )
        end

        def hive_state_path
          @hive_state_path ||= File.expand_path(Hive::Config.load(@project_root).fetch("hive_state_path"), @project_root)
        end

        def project_name
          entry = Hive::Config.registered_projects.find do |candidate|
            candidate.fetch("path") == @project_root
          end
          entry ? entry.fetch("name") : File.basename(@project_root)
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
