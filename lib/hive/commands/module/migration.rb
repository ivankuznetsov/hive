require "json"
require "time"
require "hive/config"
require "hive/commands/module/errors"
require "hive/modules/migration/patrols"
require "hive/modules/migration/report"
require "hive/modules/migration/shadow_comparator"
require "hive/modules/migration/shadow_decision_migration"
require "hive/patrol_fix/migration/cutover_state"
require "hive/patrol_fix/migration/disposition_manifest"

module Hive
  module Commands
    class Module
      class Migration
        ACTIONS = %w[
          status report cutover rollback deterministic-receipt
          deterministic-qualification patrol-fix-status patrol-fix-apply
          patrol-fix-preflight patrol-fix-rollback
        ].freeze
        MAX_REQUEST_BYTES = 16 * 1024 * 1024

        def initialize(action, project_root:, json:, stdout:, stdin: $stdin, yes: false,
                       reviewer: nil, patrol_fix_cutover_factory: nil, **)
          @action = action.to_s
          @project_root = File.expand_path(project_root)
          @json = json
          @stdout = stdout
          @stdin = stdin
          @yes = yes
          @reviewer = reviewer
          @patrol_fix_cutover_factory = patrol_fix_cutover_factory
        end

        def call
          unless ACTIONS.include?(@action)
            raise UsageError,
                  "module migration requires status, report, cutover, rollback, " \
                  "deterministic-receipt, or deterministic-qualification; " \
                  "Patrol-fix actions are patrol-fix-preflight, " \
                  "patrol-fix-status, patrol-fix-apply, or patrol-fix-rollback"
          end
          case @action
          when "status" then emit_state(read_state)
          when "report" then build_report
          when "cutover" then cutover
          when "rollback" then rollback
          when "deterministic-receipt" then deterministic_receipt
          when "deterministic-qualification" then deterministic_qualification
          when "patrol-fix-status" then patrol_fix_status
          when "patrol-fix-preflight" then patrol_fix_preflight
          when "patrol-fix-apply" then patrol_fix_apply
          when "patrol-fix-rollback" then patrol_fix_rollback
          end
        end

        private

        def patrol_fix_preflight
          request = read_request!([ "semantic_decisions" ])
          require "hive/modules/migration/patrol_fix_preflight"
          manifest = Hive::Modules::Migration::PatrolFixPreflight.new(
            project_root: @project_root, hive_state_path: hive_state_path
          ).call(
            semantic_decisions: request.fetch("semantic_decisions")
          )
          emit(
            { "manifest" => manifest.to_h },
            "Patrol-fix migration preflight: " \
            "#{manifest.to_h.dig('inventory', 'count')} sources"
          )
        rescue Hive::PatrolFix::Migration::Inventory::InvalidInventory,
               Hive::PatrolFix::Migration::SemanticGroup::InvalidGroup,
               Hive::PatrolFix::Migration::Reconciler::InvalidReconciliation,
               Hive::PatrolFix::Migration::DispositionManifest::IntegrityError => error
          raise Hive::ConfigError, error.message
        end

        def patrol_fix_status
          state = patrol_fix_state.read ||
            raise(Hive::ConfigError, "Patrol-fix migration has no preflight")
          emit(state, "Patrol-fix migration: #{state.fetch('status')}")
        end

        def patrol_fix_apply
          require_confirmation!("apply the Patrol-fix authority cutover")
          request = read_request!([ "manifest" ])
          manifest = Hive::PatrolFix::Migration::DispositionManifest.new(
            request.fetch("manifest")
          )
          manifest.verify!
          state = patrol_fix_cutover(manifest).call
          emit(state, "Patrol-fix migration: #{state.fetch('status')}")
        rescue Hive::PatrolFix::Migration::DispositionManifest::IntegrityError => error
          raise Hive::ConfigError, error.message
        end

        def patrol_fix_rollback
          require_confirmation!("roll back the Patrol-fix authority cutover")
          manifest = patrol_fix_state.manifest
          state = patrol_fix_cutover(manifest).rollback!
          emit(state, "Patrol-fix migration: #{state.fetch('status')}")
        end

        def patrol_fix_state
          Hive::PatrolFix::Migration::CutoverState.new(
            root: File.join(hive_state_path, "patrol-fix", "migration")
          )
        end

        def patrol_fix_cutover(manifest)
          factory = @patrol_fix_cutover_factory || lambda do |**arguments|
            require "hive/modules/migration/patrol_fix_cutover"
            Hive::Modules::Migration::PatrolFixCutover.new(**arguments)
          end
          factory.call(
            project_root: @project_root, hive_state_path: hive_state_path,
            manifest: manifest
          )
        end

        def deterministic_receipt
          request = read_request!(%w[metadata selector])
          receipt = Hive::Modules::Migration::Patrols.deterministic_receipt_for!(
            @project_root, selector: request.fetch("selector"),
            metadata: request.fetch("metadata"), hive_state_path: hive_state_path
          )
          emit(receipt, "Patrol deterministic evidence receipt")
        end

        def deterministic_qualification
          require_confirmation!("admit deterministic patrol qualification")
          request = read_request!(
            %w[expected_bindings expected_report_digest generated_at receipts]
          )
          projection = Hive::Modules::Migration::Patrols.admit_deterministic_qualification!(
            @project_root, receipts: request.fetch("receipts"),
            expected_bindings: request.fetch("expected_bindings"),
            generated_at: request.fetch("generated_at"),
            expected_report_digest: request.fetch("expected_report_digest"),
            hive_state_path: hive_state_path
          )
          emit(projection.to_h, "Patrol deterministic qualification admitted")
        end

        def read_request!(expected_keys)
          bytes = @stdin.read(MAX_REQUEST_BYTES + 1).to_s
          if bytes.bytesize > MAX_REQUEST_BYTES
            raise Hive::ConfigError,
                  "module migration request exceeds #{MAX_REQUEST_BYTES} bytes"
          end
          text = bytes.dup.force_encoding(Encoding::UTF_8)
          unless text.valid_encoding?
            raise Hive::ConfigError, "module migration request must be valid UTF-8 JSON"
          end
          request = JSON.parse(text)
          unless request.is_a?(Hash) && request.keys.sort == expected_keys
            raise Hive::ConfigError, "module migration request has unexpected keys"
          end
          request
        rescue JSON::ParserError, EncodingError
          raise Hive::ConfigError, "module migration request must be one JSON object"
        end

        def build_report
          require_confirmation!("review shadow evidence")
          state = read_state
          raise Hive::ConfigError, "module migration is not shadowing" unless state.fetch("status") == "shadowing"
          reviewer = @reviewer.to_s.strip
          raise Hive::ConfigError, "module migration report requires --reviewer" if reviewer.empty?

          record_source = comparator.each_record.lazy.select do |record|
            Time.iso8601(record.fetch("recorded_at")) >= Time.iso8601(state.fetch("shadow_started_at"))
          end
          report = Hive::Modules::Migration::Report.build(
            record_source: record_source,
            reviewer: reviewer,
            reviewed_at: Time.now.utc
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
