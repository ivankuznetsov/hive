require "json"
require "digest"
require "time"
require "hive/commands/module/base"
require "hive/config"
require "hive/modules/migration/migration_repository"
require "hive/modules/migration/qualification_lane_runner"
require "hive/modules/migration/qualification_run_descriptor"
require "hive/modules/migration/patrols"
require "hive/modules/migration/report"
require "hive/modules/migration/report_migration"
require "hive/repository_identity"

module Hive
  module Commands
    class Module
      class Migration
        ACTIONS =
          %w[status report qualify cutover rollback].freeze

        def initialize(action, project_root:, json:, stdout:, yes: false, reviewer: nil,
                       live_bindings_resolver: nil, run_id: nil,
                       lane: nil, environment: ENV,
                       registrations:
                         -> { Hive::Config.registered_projects },
                       repository_identity:
                         ->(root) {
                           Hive::RepositoryIdentity.current(root)
                         },
                       **)
          @action = action.to_s
          @project_root = File.expand_path(project_root)
          @json = json
          @stdout = stdout
          @yes = yes
          @reviewer = reviewer
          @live_bindings_resolver = live_bindings_resolver
          @run_id = run_id
          @lane = lane
          @environment = environment
          @registrations = registrations
          @repository_identity = repository_identity
        end

        def call
          unless ACTIONS.include?(@action)
            raise UsageError,
                  "module migration requires status, report, qualify, cutover, or rollback"
          end
          case @action
          when "status" then emit_state(read_state)
          when "report" then build_report
          when "qualify" then qualify
          when "cutover" then cutover
          when "rollback" then rollback
          end
        end

        private

        def build_report
          run_id = required_run_id!
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
                run_id: run_id,
                lane_evidence:
                  qualification_lane_evidence(run_id),
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

        def qualify
          run_id = required_run_id!
          lane = required_lane!
          descriptor =
            Hive::Modules::Migration::QualificationRunDescriptor.load(
              repository.qualification_descriptor(run_id)
            )
          result =
            Hive::Modules::Migration::QualificationLaneRunner.new(
              repository: repository,
              environment: @environment
            ).call(
              run_id: run_id,
              lane: lane,
              live_authorized:
                installed_live_authorized?(
                  descriptor, lane
                )
            )
          emit(
            result.to_h,
            "Patrol qualification #{lane}: " \
              "#{result.status} (#{result.failure_reason})"
          )
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

        def required_run_id!
          value = @run_id.to_s
          unless Hive::Modules::Migration::
            QualificationRunDescriptor::RUN_ID.match?(value)
            raise UsageError,
                  "module migration #{@action} requires --run-id " \
                  "patrol-<sha256>"
          end
          value
        end

        def required_lane!
          value = @lane.to_s
          unless Hive::Modules::Migration::
            QualificationRunDescriptor::LANES.include?(value)
            raise UsageError,
                  "module migration qualify requires --lane " \
                  "deterministic|installed"
          end
          value
        end

        def installed_live_authorized?(descriptor, lane)
          return false unless lane == "installed"
          return false unless
            @environment["HIVE_PATROL_QUALIFICATION_LIVE"] == "1"
          return false unless @yes

          expected = descriptor.project.fetch("repository")
          return false unless
            @environment[
              "HIVE_PATROL_QUALIFICATION_REPOSITORY"
            ] == expected

          real_root = File.realpath(@project_root)
          matches = Array(@registrations.call).select do |entry|
            qualification_registration_matches?(
              entry,
              descriptor.project,
              real_root,
              expected
            )
          end
          return false unless matches.one?

          @repository_identity.call(@project_root) == expected
        rescue SystemCallError, ArgumentError, KeyError, TypeError
          false
        end

        def qualification_registration_matches?(
          entry, project, real_root, repository_identity
        )
          return false unless entry.is_a?(Hash)

          File.realpath(entry.fetch("path")) == real_root &&
            entry.fetch("real_path") == real_root &&
            entry.fetch("name") == project.fetch("name") &&
            entry.fetch("project_id") ==
              project.fetch("project_id") &&
            entry.fetch("repository_identity") ==
              repository_identity
        rescue SystemCallError, ArgumentError, KeyError, TypeError
          false
        end

        def qualification_lane_evidence(run_id)
          Hive::Modules::Migration::Report::REQUIRED_LANES
            .each_with_object({}) do |lane, evidence|
              result_bytes =
                repository.qualification_lane_result(
                  run_id, lane, missing: true
                )
              next unless result_bytes

              result =
                Hive::Modules::Migration::
                  QualificationLaneResult.load(result_bytes)
              # A typed non-passed result is a complete result-only
              # sentinel. The authority provider projects its exact
              # blocker/failure; no capture is implied.
              next unless result.passed?

              files = repository.qualification_lane(
                run_id, lane
              )
              evidence[lane] =
                JSON.parse(files.fetch("bundle.json"))
            end
        rescue JSON::ParserError, EncodingError
          raise Hive::ConfigError,
                "patrol qualification lane bundle is malformed"
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
