require "hive/config"
require "hive/module_package/managed_store"
require "hive/modules/migration/patrols"
require "hive/modules/migration/report"

module Hive
  module Modules
    module Migration
      # Daemon-owned adoption retry. Installation may fence while an exact
      # legacy child is live; later ticks complete adoption only after both
      # legacy children and module attempts are quiescent.
      class Coordinator
        STAGES = {
          "patrol" => "patrol", "architecture-patrol" => "refactor-patrol"
        }.freeze

        def initialize(supervisor:, attempt_store:, registry: -> { Hive::Config.registered_projects },
                       store_factory: ->(state) { Hive::ModulePackage::ManagedStore.new(state) },
                       durable_work_probe: nil, dry_run: false)
          @supervisor = supervisor
          @attempt_store = attempt_store
          @registry = registry
          @store_factory = store_factory
          @durable_work_probe =
            durable_work_probe || method(:durable_work_quiescence)
          @dry_run = dry_run
        end

        def tick(now: Time.now.utc)
          Array(@registry.call).filter_map do |entry|
            coordinate(entry, now: now)
          rescue Hive::Error, SystemCallError, IOError, JSON::ParserError => e
            {
              project: entry && entry["name"], status: :blocked,
              reason: "#{e.class}: #{e.message}"
            }
          end
        end

        private

        def coordinate(entry, now:)
          store = @store_factory.call(entry.fetch("hive_state_path"))
          selections = store.inspect_selections.to_h { |selection| [ selection.fetch("name"), selection ] }
          return unless Patrols::MODULES.all? { |name| selections.dig(name, "installed") == true }

          state = Patrols.read_state(entry.fetch("path"), hive_state_path: entry.fetch("hive_state_path"))
          return unless state.nil? || %w[
            pending shadowing cutover_pending module rollback_pending rolled_back
          ].include?(state.fetch("status"))
          if state && %w[shadowing module rolled_back].include?(state.fetch("status"))
            return unless Patrols.shadow_decision_upgrade_required?(
              entry.fetch("path"),
              hive_state_path: entry.fetch("hive_state_path")
            )
          end
          return { project: entry.fetch("name"), status: :dry_run } if @dry_run

          migration = Patrols.new(
            project_root: entry.fetch("path"), project: entry.fetch("name"),
            hive_state_path: entry.fetch("hive_state_path"), module_store: store,
            quiescence_probe: lambda do |module_name, _root|
              quiescence(entry, module_name)
            end
          )
          outcome = case state&.fetch("status")
          when "cutover_pending"
            report = Report.load(
              Patrols.report_file(entry.fetch("path"), hive_state_path: entry.fetch("hive_state_path"))
            )
            migration.cutover!(report: report, now: now)
          when "rollback_pending" then migration.rollback!(now: now)
          else migration.adopt!(now: now)
          end
          {
            project: entry.fetch("name"), status: outcome.status.to_sym,
            blockers: outcome.blockers
          }
        end

        def quiescence(entry, module_name)
          scan = @attempt_store.scan
          return :ambiguous unless scan.invalid_records.empty?
          return :live if @supervisor.in_flight?(
            project: entry.fetch("name"), stage: STAGES.fetch(module_name)
          )
          active = scan.records.any? do |attempt|
            !attempt.final? && attempt["project"] == entry.fetch("name") &&
              attempt.module_hook? && attempt.subject["module"] == module_name
          end
          return :live if active

          status = @durable_work_probe.call(entry, module_name)
          status = status == true ? :quiescent :
            (status == false ? :live : status.to_sym)
          %i[quiescent live ambiguous].include?(status) ?
            status : :ambiguous
        rescue StandardError
          :ambiguous
        end

        def durable_work_quiescence(entry, module_name)
          project_root = entry.fetch("path")
          hive_state_path = entry.fetch("hive_state_path")
          case module_name
          when "patrol"
            require "hive/patrol/state_store"
            root = File.join(
              hive_state_path, "patrol", "occurrences"
            )
            return :quiescent unless Dir.exist?(root)

            store = Hive::Patrol::StateStore.new(
              project_root, hive_state_path: hive_state_path
            )
            store.recovery_active? ?
              :live : :quiescent
          when "architecture-patrol"
            require "hive/refactor_patrol/job_store"
            return :quiescent unless
              Hive::RefactorPatrol::JobStore.schema_state_present?(
                project_root, hive_state_path: hive_state_path
              )

            schema = Hive::RefactorPatrol::JobStore.schema_status(
              project_root,
              hive_state_path: hive_state_path,
              project: entry
            )
            return :ambiguous unless
              %w[current absent].include?(schema.fetch("status"))

            store = Hive::RefactorPatrol::JobStore.new(
              project_root,
              hive_state_path: hive_state_path,
              project: entry
            )
            if store.recovery_active? ||
               store.incomplete_jobs?
              :live
            else
              :quiescent
            end
          end
        end
      end
    end
  end
end
