require "digest"
require "json"
require "time"
require "hive/atomic_file"
require "hive/config"
require "hive/gh/repository_identity"
require "hive/module_package/managed_store"
require "hive/modules/migration/patrol_effect_index"
require "hive/modules/migration/patrol_evidence_receipt"
require "hive/modules/migration/patrol_evidence_verifier"
require "hive/modules/migration/patrol_qualification"
require "hive/modules/migration/report"
require "hive/modules/migration/report_migration"
require "hive/modules/migration/report_projection"
require "hive/modules/migration/shadow_comparator"
require "hive/modules/migration/shadow_decision_migration"
require "hive/workflow_package/canonical_json"

module Hive
  module Modules
    module Migration
      # One durable mutator-ownership epoch for both patrol products. Pending
      # transitions fence new admissions, but never terminate or hot-transfer
      # a live worker. Missing state preserves legacy behavior; corrupt state
      # fails closed so it cannot accidentally create two mutators.
      class Patrols
        MODULES = %w[patrol architecture-patrol].freeze
        LEGACY_CONFIG_KEYS = {
          "patrol" => "patrol", "architecture-patrol" => "refactor_patrol"
        }.freeze
        STATUSES = %w[pending shadowing cutover_pending module rollback_pending rolled_back].freeze
        OWNERS = %w[legacy module].freeze
        DETERMINISTIC_RECEIPT_SELECTOR_KEYS = %w[module trigger_id].freeze
        DETERMINISTIC_RECEIPT_METADATA_KEYS = %w[
          artifacts candidate_sha catalog_digest configuration_digest
          decision_class fault_steps generated_at manifest_digest repository
          reviewed_at reviewer run_id scenario_manifest_digest source_digest
        ].freeze
        private_constant :DETERMINISTIC_RECEIPT_SELECTOR_KEYS,
                         :DETERMINISTIC_RECEIPT_METADATA_KEYS
        Outcome = Data.define(:status, :state, :blockers, :restored)

        class << self
          def owner_for(project_root, module_name, hive_state_path: nil)
            state = read_state(project_root, hive_state_path: hive_state_path)
            state ? state.fetch("owners").fetch(module_name.to_s) : "legacy"
          rescue Hive::ConfigError, KeyError
            "none"
          end

          # Return the complete ownership fence in one read so effect gateways
          # never compose an owner, epoch, and admission decision from
          # different migration-state snapshots.
          def ownership_snapshot(project_root, module_name, hive_state_path: nil)
            state = read_state(project_root, hive_state_path: hive_state_path)
            return { "owner" => "legacy", "epoch" => 1, "admission" => true } unless state

            {
              "owner" => state.fetch("owners").fetch(module_name.to_s),
              "epoch" => state.fetch("epoch"),
              "admission" => state.fetch("admissions").fetch(module_name.to_s)
            }
          rescue Hive::ConfigError, KeyError
            { "owner" => "none", "epoch" => 0, "admission" => false }
          end

          def admission_allowed?(project_root, module_name, authority:, hive_state_path: nil)
            state = read_state(project_root, hive_state_path: hive_state_path)
            return authority.to_sym != :module unless state
            return true if authority.to_sym == :shadow

            state.fetch("admissions").fetch(module_name.to_s) &&
              state.fetch("owners").fetch(module_name.to_s) == authority.to_s
          rescue Hive::ConfigError, KeyError
            false
          end

          def module_mode(project_root, module_name, configured_shadow:, hive_state_path: nil)
            state = read_state(project_root, hive_state_path: hive_state_path)
            return configured_shadow ? :shadow : :fenced unless state
            return :fenced unless state.fetch("admissions").fetch(module_name.to_s)

            state.fetch("owners").fetch(module_name.to_s) == "module" ? :mutator : :shadow
          rescue Hive::ConfigError, KeyError
            :fenced
          end

          def diagnostic(project_root, module_name, hive_state_path: nil)
            state = read_state(project_root, hive_state_path: hive_state_path)
            return { "status" => "unadopted", "owner" => "legacy", "admission" => false } unless state

            {
              "status" => state.fetch("status"),
              "owner" => state.fetch("owners").fetch(module_name.to_s),
              "admission" => state.fetch("admissions").fetch(module_name.to_s),
              "blocker" => state.fetch("blockers")[module_name.to_s]
            }
          rescue Hive::ConfigError, KeyError => e
            { "status" => "corrupt", "owner" => "none", "admission" => false,
              "blocker" => e.message }
          end

          def reviewed_config(project_root, module_name, hive_state_path: nil)
            state = read_state(project_root, hive_state_path: hive_state_path)
            return Hive::Config.load(project_root) unless state

            binding = state&.dig("bindings", module_name.to_s)
            config = binding&.fetch("reviewed_config", nil)
            digest = binding&.fetch("reviewed_config_digest", nil)
            unless config.is_a?(Hash) && digest.to_s.match?(/\A[0-9a-f]{64}\z/) &&
                   ::Digest::SHA256.hexdigest(canonical(config)) == digest
              raise Hive::ConfigError, "patrol module reviewed configuration is unavailable"
            end

            JSON.parse(canonical(config))
          end

          # Hold the migration state lock from final ownership validation
          # through child registration. Cutover/rollback take this lock
          # exclusively, so a precomputed legacy candidate cannot cross an
          # ownership epoch while it is being reserved and spawned.
          def with_admission(project_root, module_name, authority:, hive_state_path: nil)
            with_migration_lock(
              project_root, hive_state_path: hive_state_path, shared: true
            ) do
              yield admission_allowed?(
                project_root, module_name, authority: authority,
                hive_state_path: hive_state_path
              )
            end
          end

          def with_migration_lock(project_root, hive_state_path: nil, shared: true, &block)
            Report.with_locked_storage(
              report_file(project_root, hive_state_path: hive_state_path),
              shared: shared
            ) { block.call }
          end

          def read_state(project_root, hive_state_path: nil)
            path = state_file(project_root, hive_state_path: hive_state_path)
            return nil unless File.file?(path)

            bytes = File.binread(path)
            state = JSON.parse(bytes)
            unless bytes == canonical(state)
              raise Hive::ConfigError, "patrol module migration state is not canonical"
            end
            validate_state!(state)
            state
          rescue JSON::ParserError, EncodingError, SystemCallError => e
            raise Hive::ConfigError, "patrol module migration state is unreadable: #{e.message}"
          end

          def state_file(project_root, hive_state_path: nil)
            root = File.expand_path(project_root)
            state = hive_state_path || ".hive-state"
            File.join(
              File.expand_path(state, root), "module-runtime", "migration", "patrols.json"
            )
          end

          def report_file(project_root, hive_state_path: nil)
            File.join(File.dirname(state_file(project_root, hive_state_path: hive_state_path)), "report.json")
          end

          # Build one receipt from the immutable comparison record selected by
          # product identity. The harness supplies only candidate metadata; it
          # cannot substitute captures, projections, or effect observations.
          def deterministic_receipt_for!(project_root, selector:, metadata:,
                                         hive_state_path: nil)
            selector_label = "patrol deterministic receipt selector"
            exact_string_keys!(
              selector, DETERMINISTIC_RECEIPT_SELECTOR_KEYS,
              label: selector_label
            )
            module_name = selector.fetch("module")
            trigger_id = selector.fetch("trigger_id")
            valid_selector = MODULES.include?(module_name) &&
              trigger_id.is_a?(String) && trigger_id.valid_encoding? &&
              !trigger_id.empty? &&
              trigger_id.bytesize <= PatrolEvidenceReceipt::MAX_LABEL_BYTES
            PatrolEvidence.malformed!(selector_label) unless valid_selector
            exact_string_keys!(
              metadata, DETERMINISTIC_RECEIPT_METADATA_KEYS,
              label: "patrol deterministic receipt metadata"
            )

            with_migration_lock(
              project_root, hive_state_path: hive_state_path, shared: false
            ) do
              comparator = ShadowComparator.new(
                root: File.join(
                  File.dirname(
                    state_file(project_root, hive_state_path: hive_state_path)
                  ),
                  "shadow"
                ),
                admission_lock: ->(shared: true, &block) { block.call }
              )
              matches = []
              comparator.each_record(module_name) do |record|
                matches << record if record.dig("trigger", "id") == trigger_id
                break if matches.size > 1
              end
              if matches.empty?
                raise Hive::ConfigError,
                      "patrol deterministic receipt evidence was not found"
              end
              unless matches.one?
                raise Hive::ConfigError,
                      "patrol deterministic receipt evidence is ambiguous"
              end

              record = matches.fetch(0)
              unless record.fetch("comparable") &&
                     record.fetch("unexplained_differences").empty? &&
                     record.fetch("duplicate_effects").empty?
                raise Hive::ConfigError,
                      "patrol deterministic receipt evidence is inconsistent"
              end
              unless metadata.fetch("configuration_digest") ==
                     record.fetch("configuration_digest")
                raise Hive::ConfigError,
                      "patrol deterministic receipt configuration changed"
              end
              capture_repository = record.dig(
                "legacy_capture", "project", "repository"
              )
              metadata_repository = metadata.fetch("repository", nil)
              repository_id = metadata_repository.fetch("id", nil) if
                metadata_repository.is_a?(Hash)
              unless canonical_repository_target?(capture_repository) &&
                     capture_repository == repository_id
                raise Hive::ConfigError,
                      "patrol deterministic receipt repository changed"
              end

              PatrolEvidenceReceipt.build(
                capture: record.fetch("legacy_capture"),
                module_projection: record.fetch("module_decision"),
                effects: record.fetch("legacy_effects") +
                  record.fetch("module_effects"),
                **metadata.transform_keys(&:to_sym)
              ).to_h
            end
          end

          # Admit deterministic evidence without giving the E2E harness access
          # to verifier tokens or report construction. The caller supplies raw
          # receipt documents plus independently computed expected bindings;
          # this facade owns verification, qualification, and the report CAS.
          def admit_deterministic_qualification!(
            project_root, receipts:, expected_bindings:, generated_at:,
            expected_report_digest:, hive_state_path: nil
          )
            valid_inputs = receipts.is_a?(Array) &&
              expected_bindings.is_a?(Array) &&
              receipts.size == expected_bindings.size &&
              receipts.size.between?(1, PatrolQualification::MAX_RECEIPTS) &&
              receipts.all?(Hash) && expected_bindings.all?(Hash) &&
              expected_report_digest.is_a?(String) &&
              expected_report_digest.match?(/\A[0-9a-f]{64}\z/)
            unless valid_inputs
              raise Hive::ConfigError,
                    "patrol deterministic qualification admission is malformed"
            end

            effects = []
            verified = receipts.each_index.map do |index|
              receipt = PatrolEvidenceVerifier.verify(
                receipt: receipts.fetch(index),
                expected_bindings: expected_bindings.fetch(index)
              )
              if effects.size + receipt.effects.size >
                   PatrolEffectIndex::MAX_RECEIPTS
                raise Hive::ConfigError,
                      "patrol deterministic qualification admission is malformed"
              end
              effects.concat(receipt.effects)
              receipt
            end.freeze
            qualification = PatrolQualification.build(
              lane: "deterministic", verified_receipts: verified,
              effect_index: PatrolEffectIndex.build(receipts: effects),
              generated_at: generated_at
            )
            path = report_file(
              project_root, hive_state_path: hive_state_path
            )
            projection = ReportProjection.merge(
              existing: Report.load(path), qualification: qualification,
              generated_at: generated_at
            )
            Report.write_projection(
              path, projection, expected_digest: expected_report_digest
            )
            projection
          end

          def shadow_decision_upgrade_required?(project_root,
                                                hive_state_path: nil)
            migration_dir = File.dirname(
              state_file(project_root, hive_state_path: hive_state_path)
            )
            ShadowDecisionMigration.ensure_complete!(
              root: File.join(migration_dir, "shadow")
            )
            ReportMigration.required?(
              report_file(project_root, hive_state_path: hive_state_path)
            )
          rescue Hive::ConfigError
            true
          end

          def validate_state!(state)
            keys = %w[
              admissions bindings blockers cutover_at cutover_selections epoch owners project
              project_root rollback_at schema schema_version shadow_started_at status updated_at watermarks
            ]
            valid = state.is_a?(Hash) && state.keys.sort == keys.sort &&
                    state["schema"] == "hive-module-migration" && state["schema_version"] == 1 &&
                    STATUSES.include?(state["status"]) && state["epoch"].is_a?(Integer) && state["epoch"].positive? &&
                    state["owners"].keys.sort == MODULES.sort &&
                    state["owners"].values.all? { |owner| OWNERS.include?(owner) } &&
                    state["admissions"].keys.sort == MODULES.sort &&
                    state["admissions"].values.all? { |value| [ true, false ].include?(value) } &&
                    state["bindings"].is_a?(Hash) && state["blockers"].is_a?(Hash) &&
                    state["cutover_selections"].is_a?(Hash) && state["watermarks"].is_a?(Hash)
            raise Hive::ConfigError, "patrol module migration state is malformed" unless valid

            state
          rescue NoMethodError
            raise Hive::ConfigError, "patrol module migration state is malformed"
          end

          def exact_string_keys!(value, keys, label:)
            unless value.is_a?(Hash) &&
                   value.keys.all? { |key| key.instance_of?(String) }
              PatrolEvidence.malformed!(label)
            end
            PatrolEvidence.exact_keys!(value, keys, label: label)
          end
          private :exact_string_keys!

          def canonical_repository_target?(value)
            return false unless value.is_a?(String)

            host, owner, name, *extra = value.split("/", -1)
            return false unless extra.empty?

            Hive::Gh::RepositoryIdentity.github_repository_target(
              "#{owner}/#{name}", host
            ) == value
          rescue Hive::GhError
            false
          end
          private :canonical_repository_target?

          def canonical(value) = Hive::WorkflowPackage::CanonicalJSON.generate(value)
        end

        attr_reader :project_root, :hive_state_path, :store

        def initialize(project_root:, project: nil, hive_state_path: nil, module_store: nil,
                       quiescence_probe: ->(_module_name, _root) { :ambiguous })
          @project_root = File.expand_path(project_root)
          @project = project || File.basename(@project_root)
          cfg = Hive::Config.load(@project_root)
          @hive_state_path = File.expand_path(
            hive_state_path || cfg.fetch("hive_state_path"), @project_root
          )
          @store = module_store || Hive::ModulePackage::ManagedStore.new(@hive_state_path)
          @quiescence_probe = quiescence_probe
          @migration_dir = File.dirname(self.class.state_file(@project_root, hive_state_path: @hive_state_path))
        end

        def read = self.class.read_state(project_root, hive_state_path: hive_state_path)

        def adopt!(now: Time.now.utc)
          immediate = nil
          migration_ready = false
          existing_state = nil
          migration_upgrade_required =
            self.class.shadow_decision_upgrade_required?(
              project_root, hive_state_path: hive_state_path
            )
          mutate do |storage|
            migration_upgrade_required = true if
              !migration_upgrade_required &&
              report_upgrade_required_locked?(storage)
            state = read || initial_state(now)
            stable = %w[shadowing module].include?(state.fetch("status"))
            stable_upgrade_state = %w[shadowing module rolled_back].include?(
              state.fetch("status")
            )
            interrupted_upgrade = stable_upgrade_state &&
              !state.fetch("admissions").values.all?
            legacy_stable =
              stable_upgrade_state &&
              (migration_upgrade_required || interrupted_upgrade)
            if stable && !migration_upgrade_required && !interrupted_upgrade
              immediate = outcome("already_current", state)
              next
            end
            if legacy_stable
              blockers = quiescence_blockers
              fenced = state.merge(
                "admissions" => MODULES.to_h { |name| [ name, false ] },
                "blockers" => blockers,
                "updated_at" => timestamp(now)
              )
              write(fenced)
              if blockers.empty?
                existing_state = state
                migration_ready = :existing
              else
                immediate = outcome(state.fetch("status"), fenced, blockers)
              end
              next
            end
            bindings = module_bindings
            pending = state.merge(
              "status" => "pending", "bindings" => bindings,
              "admissions" => MODULES.to_h { |name| [ name, false ] },
              "blockers" => {}, "cutover_selections" => {}, "watermarks" => {},
              "shadow_started_at" => nil, "cutover_at" => nil,
              "updated_at" => timestamp(now)
            )
            write(pending)
            blockers = quiescence_blockers
            if blockers.empty?
              migration_ready = true
            else
              fenced = pending.merge("blockers" => blockers, "updated_at" => timestamp(now))
              write(fenced)
              immediate = outcome("pending", fenced, blockers)
            end
          end
          return immediate if immediate
          return upgrade_existing_shadow_state!(existing_state, now) if migration_ready == :existing
          unless migration_ready
            raise Hive::ConfigError,
                  "patrol module migration admission is unavailable"
          end

          # Admission is durably closed before the one-off v1 inventory starts.
          # The migrator takes the same exclusive migration lock, independently
          # proves old workers quiescent, converts/checkpoints every file, and
          # stamps only after a zero-v1 rescan. Runtime readers remain v2-only.
          migrate_shadow_decisions!

          mutate do |storage|
            state = read || raise(
              Hive::ConfigError,
              "patrol module migration state disappeared during adoption"
            )
            if %w[shadowing module].include?(state.fetch("status"))
              next outcome("already_current", state)
            end
            unless state.fetch("status") == "pending"
              raise Hive::ConfigError,
                    "patrol module migration changed during adoption"
            end
            blockers = quiescence_blockers
            unless blockers.empty?
              fenced = state.merge(
                "blockers" => blockers, "updated_at" => timestamp(now)
              )
              write(fenced)
              next outcome("pending", fenced, blockers)
            end
            migrate_report!(storage, now)

            active = state.merge(
              "status" => "shadowing",
              "bindings" => module_bindings,
              "admissions" => MODULES.to_h { |name| [ name, true ] },
              "blockers" => {},
              "shadow_started_at" =>
                state["shadow_started_at"] || timestamp(now),
              "updated_at" => timestamp(now)
            )
            write(active)
            outcome("shadowing", active)
          end
        end

        def cutover!(report:, now: Time.now.utc)
          if report.is_a?(ReportProjection)
            raise Hive::ConfigError,
                  "patrol module migration report v2 requires separately authorized cutover"
          end
          unless report.respond_to?(:eligible?) && report.eligible?
            blockers = report.respond_to?(:blockers) ? report.blockers : [ "report_invalid" ]
            raise Hive::ConfigError, "patrol module cutover evidence is incomplete: #{blockers.join(', ')}"
          end
          mutate do
            state = read or raise Hive::ConfigError, "patrol module migration has not been adopted"
            unless %w[shadowing cutover_pending].include?(state.fetch("status"))
              raise Hive::ConfigError, "patrol module migration is not ready for cutover"
            end
            assert_report_bindings!(state, report)
            assert_current_report!(report, now)
            pending = state.merge(
              "status" => "cutover_pending",
              "admissions" => MODULES.to_h { |name| [ name, false ] },
              "blockers" => {}, "updated_at" => timestamp(now)
            )
            write(pending)
            blockers = quiescence_blockers
            unless blockers.empty?
              fenced = pending.merge("blockers" => blockers)
              write(fenced)
              next outcome("cutover_pending", fenced, blockers)
            end

            selections = MODULES.to_h do |name|
              selection = installed_selection!(name)
              [ name, selection.fetch("active") ]
            end
            active = pending.merge(
              "status" => "module", "epoch" => pending.fetch("epoch") + 1,
              "owners" => MODULES.to_h { |name| [ name, "module" ] },
              "admissions" => MODULES.to_h { |name| [ name, true ] },
              "cutover_at" => timestamp(now), "cutover_selections" => selections,
              "watermarks" => MODULES.to_h { |name| [ name, timestamp(now) ] },
              "blockers" => {}, "updated_at" => timestamp(now)
            )
            write(active)
            outcome("module", active)
          end
        end

        def rollback!(now: Time.now.utc)
          mutate do
            state = read or raise Hive::ConfigError, "patrol module migration has not been adopted"
            unless %w[module rollback_pending].include?(state.fetch("status"))
              raise Hive::ConfigError, "patrol module ownership is not active"
            end
            pending = state.merge(
              "status" => "rollback_pending",
              "admissions" => MODULES.to_h { |name| [ name, false ] },
              "blockers" => {}, "updated_at" => timestamp(now)
            )
            write(pending)
            blockers = quiescence_blockers
            unless blockers.empty?
              fenced = pending.merge("blockers" => blockers)
              write(fenced)
              next outcome("rollback_pending", fenced, blockers)
            end

            restored = restore_previous_selections(pending, now)
            legacy = pending.merge(
              "status" => "rolled_back", "epoch" => pending.fetch("epoch") + 1,
              "owners" => MODULES.to_h { |name| [ name, "legacy" ] },
              "admissions" => MODULES.to_h { |name| [ name, true ] },
              "rollback_at" => timestamp(now), "blockers" => {},
              "updated_at" => timestamp(now)
            )
            write(legacy)
            outcome("rolled_back", legacy, {}, restored)
          end
        end

        private

        def mutate(&block)
          Report.with_locked_storage(
            self.class.report_file(
              project_root, hive_state_path: hive_state_path
            )
          ) { |storage| block.call(storage) }
        end

        def initial_state(now)
          {
            "schema" => "hive-module-migration", "schema_version" => 1,
            "project" => @project.to_s, "project_root" => project_root,
            "epoch" => 1, "status" => "pending",
            "owners" => MODULES.to_h { |name| [ name, "legacy" ] },
            "admissions" => MODULES.to_h { |name| [ name, false ] },
            "bindings" => {}, "blockers" => {}, "cutover_selections" => {},
            "watermarks" => {}, "shadow_started_at" => nil, "cutover_at" => nil,
            "rollback_at" => nil, "updated_at" => timestamp(now)
          }
        end

        def module_bindings
          cfg = Hive::Config.load(project_root)
          MODULES.to_h do |name|
            selection = installed_selection!(name)
            active = selection.fetch("active")
            config_key = LEGACY_CONFIG_KEYS.fetch(name)
            [ name, {
              "selection_epoch" => selection.fetch("epoch"),
              "source_commit" => active.fetch("source_commit"),
              "configuration_digest" => active.fetch("configuration_digest"),
              "legacy_config_digest" => digest(cfg.fetch(config_key)),
              "reviewed_config" => cfg,
              "reviewed_config_digest" => digest(cfg),
              "state_roots" => legacy_state_roots(name)
            } ]
          end
        end

        def installed_selection!(name)
          selection = store.inspect_selection(name, include_tombstone: true)
          unless selection&.fetch("installed") && selection.fetch("enabled") && selection["active"]
            raise Hive::ConfigError, "module #{name.inspect} must be installed and enabled before patrol migration"
          end
          store.configuration(name, selection.dig("active", "configuration_digest"))
          selection
        end

        def legacy_state_roots(name)
          roots = if name == "patrol"
            [ File.join(hive_state_path, "patrol") ]
          else
            [ File.join(hive_state_path, "refactor_patrol") ]
          end
          roots.each do |path|
            next unless File.exist?(path)
            raise Hive::ConfigError, "legacy patrol state is unreadable" unless File.readable?(path)
          end
          roots
        end

        def quiescence_blockers
          MODULES.filter_map do |name|
            result = @quiescence_probe.call(name, project_root)
            status = result == true ? :quiescent : (result == false ? :live : result.to_sym)
            [ name, status.to_s ] unless status == :quiescent
          rescue StandardError
            [ name, "ambiguous" ]
          end.to_h
        end

        def migrate_shadow_decisions!
          ShadowDecisionMigration.migrate!(
            root: File.join(@migration_dir, "shadow"),
            quiescence_probe: lambda do
              blockers = quiescence_blockers
              blockers.empty? ? :quiescent :
                blockers.value?("live") ? :live : :ambiguous
            end
          )
        end

        def migrate_report!(storage, now)
          ReportMigration.forward_locked(
            storage: storage, qualifications: [], generated_at: now
          )
        end

        def report_upgrade_required_locked?(storage)
          ReportMigration.required_locked?(storage)
        rescue Hive::ConfigError
          true
        end

        # Older migration state can predate the v2 shadow-decision inventory.
        # Keep its ownership mode intact, but close both admissions before the
        # one-off conversion and restore them only after the exclusive migrator
        # proves every record is v2.
        def upgrade_existing_shadow_state!(previous, now)
          migrate_shadow_decisions!
          mutate do |storage|
            state = read || raise(
              Hive::ConfigError,
              "patrol module migration state disappeared during shadow upgrade"
            )
            unless state.fetch("status") == previous.fetch("status") &&
                   state.fetch("admissions").values.all? { |admission| admission == false }
              raise Hive::ConfigError,
                    "patrol module migration changed during shadow upgrade"
            end
            migrate_report!(storage, now)

            restored = state.merge(
              "admissions" => MODULES.to_h { |name| [ name, true ] },
              "blockers" => {},
              "updated_at" => timestamp(now)
            )
            write(restored)
            outcome("already_current", restored)
          end
        end

        def assert_report_bindings!(state, report)
          report.configuration_digests.each do |name, digest_value|
            unless state.dig("bindings", name, "configuration_digest") == digest_value
              raise Hive::ConfigError, "patrol module shadow report configuration changed"
            end
          end
        end

        def assert_current_report!(report, now)
          return unless report.respond_to?(:payload)

          payload = report.payload
          comparator = Hive::Modules::Migration::ShadowComparator.new(
            root: File.join(@migration_dir, "shadow"),
            admission_lock: ->(shared: true, &block) { block.call }
          )
          current = Hive::Modules::Migration::Report.build(
            record_source: comparator.each_record,
            reviewer: payload.fetch("reviewer"),
            reviewed_at: payload.fetch("reviewed_at"),
            generated_at: now
          )
          return if current.eligible? && current.configuration_digests == report.configuration_digests

          raise Hive::ConfigError,
                "patrol module cutover evidence is stale: #{current.blockers.join(', ')}"
        end

        def restore_previous_selections(state, now)
          MODULES.to_h do |name|
            expected = state.fetch("cutover_selections").fetch(name)
            before = store.inspect_selection(name, include_tombstone: true)
            if before.fetch("active") == expected
              after = store.restore_previous(name, expected_active: expected, now: now)
              value = before.fetch("active") != after.fetch("active") ? "previous" : "no_previous"
            elsif before.fetch("previous", nil) == expected
              value = "already_restored"
            else
              raise Hive::ConfigError, "module rollback active generation changed"
            end
            [ name, value ]
          end
        end

        def write(state)
          self.class.validate_state!(state)
          Hive::AtomicFile.write(
            self.class.state_file(project_root, hive_state_path: hive_state_path),
            self.class.canonical(state), mode: 0o600
          )
          state
        end

        def outcome(status, state, blockers = {}, restored = {})
          Outcome.new(status: status, state: state, blockers: blockers, restored: restored)
        end

        def digest(value) = ::Digest::SHA256.hexdigest(self.class.canonical(value))
        def timestamp(value) = value.utc.iso8601(6)
      end
    end
  end
end
