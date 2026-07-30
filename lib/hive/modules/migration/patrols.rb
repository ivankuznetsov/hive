require "digest"
require "json"
require "time"
require "hive/config"
require "hive/module_package/managed_store"
require "hive/modules/migration/migration_repository"
require "hive/modules/migration/live_bindings_resolver"
require "hive/modules/migration/report"
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
            migration_repository(
              project_root,
              hive_state_path: hive_state_path
            ).with_lock(shared: true) do
              yield admission_allowed?(
                project_root, module_name, authority: authority,
                hive_state_path: hive_state_path
              )
            end
          end

          def with_migration_lock(project_root, hive_state_path: nil, shared: true, &block)
            migration_repository(
              project_root,
              hive_state_path: hive_state_path
            ).with_lock(shared: shared, &block)
          end

          def read_state(project_root, hive_state_path: nil)
            bytes = migration_repository(
              project_root,
              hive_state_path: hive_state_path
            ).read_state_bytes
            return nil unless bytes

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
            migration_repository(
              project_root,
              hive_state_path: hive_state_path
            ).state_path
          end

          def report_file(project_root, hive_state_path: nil)
            migration_repository(
              project_root,
              hive_state_path: hive_state_path
            ).report_path
          end

          def shadow_decision_upgrade_required?(project_root,
                                                hive_state_path: nil)
            migration_dir = File.dirname(
              state_file(project_root, hive_state_path: hive_state_path)
            )
            ShadowDecisionMigration.ensure_complete!(
              root: File.join(migration_dir, "shadow")
            )
            false
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

          def canonical(value) = Hive::WorkflowPackage::CanonicalJSON.generate(value)

          def migration_repository(project_root, hive_state_path: nil)
            MigrationRepository.for(
              project_root: project_root,
              hive_state_path: hive_state_path
            )
          end
        end

        attr_reader :project_root, :hive_state_path, :store

        def initialize(project_root:, project: nil, hive_state_path: nil, module_store: nil,
                       quiescence_probe: ->(_module_name, _root) { :ambiguous },
                       project_provider: nil,
                       run_authority_provider: nil)
          @project_root = File.expand_path(project_root)
          cfg = Hive::Config.load(@project_root)
          @hive_state_path = File.expand_path(
            hive_state_path || cfg.fetch("hive_state_path"), @project_root
          )
          @store = module_store || Hive::ModulePackage::ManagedStore.new(@hive_state_path)
          @project = if project.is_a?(Hash)
            project["name"] || project[:name]
          else
            project
          end
          @project ||= File.basename(@project_root)
          @project_provider =
            project_provider || method(:resolve_live_project_binding)
          @run_authority_provider = run_authority_provider
          @quiescence_probe = quiescence_probe
          @repository = MigrationRepository.for(
            project_root: @project_root,
            hive_state_path: @hive_state_path
          )
          @migration_dir = @repository.root
        end

        def read = self.class.read_state(project_root, hive_state_path: hive_state_path)

        def adopt!(now: Time.now.utc)
          immediate = nil
          migration_ready = false
          existing_state = nil
          shadow_upgrade_required =
            self.class.shadow_decision_upgrade_required?(
              project_root, hive_state_path: hive_state_path
            )
          mutate do
            state = read || initial_state(now)
            stable = %w[shadowing module].include?(state.fetch("status"))
            legacy_stable =
              (stable || state.fetch("status") == "rolled_back") &&
              shadow_upgrade_required
            if stable && !shadow_upgrade_required
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

          mutate do
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
          mutate do
            store.with_selection_snapshot(
              MODULES,
              include_tombstones: true
            ) do |snapshot|
              cutover_with_snapshot!(
                report,
                snapshot,
                now
              )
            end
          end
        end

        def recover_cutover_pending_for_requalification!(
          now: Time.now.utc
        )
          mutate do
            state = read || raise(
              Hive::ConfigError,
              "patrol module migration has not been adopted"
            )
            unless state.fetch("status") == "cutover_pending"
              raise Hive::ConfigError,
                    "patrol module migration is not pending cutover"
            end
            unless state.fetch("owners").values.uniq == [ "legacy" ]
              raise Hive::ConfigError,
                    "patrol module pending cutover ownership is contradictory"
            end

            store.with_selection_snapshot(
              MODULES,
              include_tombstones: true
            ) do |snapshot|
              recover_with_snapshot!(state, snapshot, now)
            end
          end
        end

        def resume_cutover_pending!(now: Time.now.utc)
          mutate do
            store.with_selection_snapshot(
              MODULES,
              include_tombstones: true
            ) do |snapshot|
              state = read || raise(
                Hive::ConfigError,
                "patrol module migration has not been adopted"
              )
              report = @repository.load_report(
                live_bindings_resolver:
                  live_bindings_resolver(snapshot)
              )
              if report.qualification.ready_for_operator?
                cutover_with_snapshot!(report, snapshot, now)
              else
                recover_with_snapshot!(state, snapshot, now)
              end
            end
          end
        end

        def load_report_for_cutover
          mutate do
            store.with_selection_snapshot(
              MODULES,
              include_tombstones: true
            ) do |snapshot|
              @repository.load_report(
                live_bindings_resolver:
                  live_bindings_resolver(snapshot)
              )
            end
          end
        end

        # Callers that already hold the migration repository lock may build a
        # report from one exact module-store snapshot without reversing the
        # repository -> module-store lock order.
        def with_live_bindings_resolver
          store.with_selection_snapshot(
            MODULES,
            include_tombstones: true
          ) do |snapshot|
            yield live_bindings_resolver(snapshot)
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
          @repository.with_lock(&block)
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
          store.with_selection_snapshot(
            MODULES,
            include_tombstones: true
          ) do |snapshot|
            module_bindings_from_snapshot(snapshot, cfg)
          end
        end

        def module_bindings_from_snapshot(snapshot, cfg)
          MODULES.to_h do |name|
            selection = installed_selection!(name, snapshot)
            active = selection.fetch("active")
            config_key = LEGACY_CONFIG_KEYS.fetch(name)
            [ name, {
              "selection_epoch" => selection.fetch("epoch"),
              "active_selection" => active,
              "source_commit" => active.fetch("source_commit"),
              "configuration_digest" =>
                active.fetch("configuration_digest"),
              "legacy_config_digest" =>
                digest(cfg.fetch(config_key)),
              "reviewed_config" => cfg,
              "reviewed_config_digest" => digest(cfg),
              "state_roots" => legacy_state_roots(name)
            } ]
          end
        end

        def installed_selection!(name, snapshot)
          selection = snapshot.fetch(name)
          unless selection&.fetch("installed") && selection.fetch("enabled") && selection["active"]
            raise Hive::ConfigError, "module #{name.inspect} must be installed and enabled before patrol migration"
          end
          store.configuration(name, selection.dig("active", "configuration_digest"))
          selection
        end

        def cutover_with_snapshot!(report, snapshot, now)
          unless report.is_a?(Report)
            raise Hive::ConfigError,
                  "patrol module cutover evidence is incomplete: " \
                  "qualification_invalid"
          end
          state = read or raise(
            Hive::ConfigError,
            "patrol module migration has not been adopted"
          )
          unless %w[shadowing cutover_pending].include?(
            state.fetch("status")
          )
            raise Hive::ConfigError,
                  "patrol module migration is not ready for cutover"
          end
          MODULES.each do |name|
            installed_selection!(name, snapshot)
          end
          assert_active_selections!(state, snapshot)
          persisted_report = @repository.load_report(
            live_bindings_resolver:
              live_bindings_resolver(snapshot)
          )
          unless report.payload.fetch("report_id") ==
                 persisted_report.payload.fetch("report_id")
            raise Hive::ConfigError,
                  "patrol module cutover evidence changed"
          end
          qualification = persisted_report.qualification
          unless qualification.is_a?(PatrolQualification) &&
                 qualification.ready_for_operator?
            blockers = qualification.is_a?(PatrolQualification) ?
              qualification.blockers :
              [ "qualification_invalid" ]
            raise Hive::ConfigError,
                  "patrol module cutover evidence is incomplete: " \
                  "#{blockers.join(', ')}"
          end
          assert_report_bindings!(
            state,
            qualification,
            snapshot
          )
          pending = state.merge(
            "status" => "cutover_pending",
            "admissions" =>
              MODULES.to_h { |name| [ name, false ] },
            "blockers" => {},
            "updated_at" => timestamp(now)
          )
          write(pending)
          blockers = quiescence_blockers
          unless blockers.empty?
            fenced = pending.merge("blockers" => blockers)
            write(fenced)
            return outcome(
              "cutover_pending",
              fenced,
              blockers
            )
          end

          selections = snapshot.to_h do |name, selection|
            [ name, selection.fetch("active") ]
          end
          active = pending.merge(
            "status" => "module",
            "epoch" => pending.fetch("epoch") + 1,
            "owners" =>
              MODULES.to_h { |name| [ name, "module" ] },
            "admissions" =>
              MODULES.to_h { |name| [ name, true ] },
            "cutover_at" => timestamp(now),
            "cutover_selections" => selections,
            "watermarks" =>
              MODULES.to_h { |name| [ name, timestamp(now) ] },
            "blockers" => {},
            "updated_at" => timestamp(now)
          )
          write(active)
          outcome("module", active)
        end

        def recover_with_snapshot!(state, snapshot, now)
          unless state.fetch("status") == "cutover_pending"
            raise Hive::ConfigError,
                  "patrol module migration is not pending cutover"
          end
          unless state.fetch("owners").values.uniq == [ "legacy" ]
            raise Hive::ConfigError,
                  "patrol module pending cutover ownership is contradictory"
          end
          recovered = state.merge(
            "status" => "shadowing",
            "bindings" => module_bindings_from_snapshot(
              snapshot,
              Hive::Config.load(project_root)
            ),
            "admissions" =>
              MODULES.to_h { |name| [ name, true ] },
            "blockers" => {},
            "cutover_selections" => {},
            "cutover_at" => nil,
            "watermarks" => {},
            "shadow_started_at" => timestamp(now),
            "updated_at" => timestamp(now)
          )
          write(recovered)
          outcome("shadowing", recovered)
        end

        def live_bindings_resolver(snapshot)
          LiveBindingsResolver.new(
            project_provider: @project_provider,
            module_selections: snapshot,
            run_authority_provider: @run_authority_provider
          )
        end

        def resolve_live_project_binding
          project_realpath = File.realpath(@project_root)
          matches = Array(Hive::Config.registered_projects).select do |entry|
            next false unless entry.is_a?(Hash)

            File.realpath(entry.fetch("path")) == project_realpath
          rescue KeyError, SystemCallError, TypeError
            false
          end
          if matches.empty?
            return project_resolution(
              nil,
              "live_project_registration_missing"
            )
          end
          if matches.length != 1
            return project_resolution(
              nil,
              "live_project_registration_ambiguous"
            )
          end

          entry = matches.fetch(0)
          project_id = entry["project_id"]
          name = entry["name"]
          unless project_id.is_a?(String) && !project_id.empty? &&
                 name.is_a?(String) && !name.empty?
            return project_resolution(
              nil,
              "live_project_registration_malformed"
            )
          end

          stored = entry["repository_identity"]
          current = Hive::RepositoryIdentity.current(@project_root)
          project = {
            "project_id" => project_id,
            "name" => name,
            "repository" => current
          }
          unless stored.is_a?(String) && !stored.empty?
            return project_resolution(
              project,
              "live_project_repository_identity_missing"
            )
          end
          unless current.is_a?(String) && !current.empty?
            return project_resolution(
              project,
              "live_project_repository_identity_unresolved"
            )
          end
          unless current == stored
            return project_resolution(
              project,
              "live_project_repository_identity_mismatch"
            )
          end

          project_resolution(project)
        rescue SystemCallError
          project_resolution(
            nil,
            "live_project_realpath_unresolved"
          )
        rescue Hive::Error
          project_resolution(
            nil,
            "live_project_registration_unresolved"
          )
        end

        def project_resolution(project, blocker = nil)
          LiveBindingsResolver::ProjectResolution.new(
            project: project,
            blockers: [ blocker ].compact.freeze
          ).freeze
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

        # Older migration state can predate the v2 shadow-decision inventory.
        # Keep its ownership mode intact, but close both admissions before the
        # one-off conversion and restore them only after the exclusive migrator
        # proves every record is v2.
        def upgrade_existing_shadow_state!(previous, now)
          migrate_shadow_decisions!
          mutate do
            state = read || raise(
              Hive::ConfigError,
              "patrol module migration state disappeared during shadow upgrade"
            )
            unless state.fetch("status") == previous.fetch("status") &&
                   state.fetch("admissions").values.all? { |admission| admission == false }
              raise Hive::ConfigError,
                    "patrol module migration changed during shadow upgrade"
            end

            restored = state.merge(
              "admissions" => previous.fetch("admissions"),
              "blockers" => {},
              "updated_at" => timestamp(now)
            )
            write(restored)
            outcome("already_current", restored)
          end
        end

        def assert_report_bindings!(state, qualification, snapshot)
          assert_active_selections!(state, snapshot)
          qualification.configuration_digests.each do |name, digest_value|
            unless state.dig("bindings", name, "configuration_digest") == digest_value
              raise Hive::ConfigError, "patrol module shadow report configuration changed"
            end
          end
          owner_epochs = qualification.verifications.values.flat_map do |verification|
            verification.effect_index.entries.map do |entry|
              entry.fetch("owner_epoch")
            end
          end.uniq
          unless owner_epochs == [ state.fetch("epoch") ]
            raise Hive::ConfigError,
                  "patrol module shadow report ownership epoch changed"
          end
        end

        def assert_active_selections!(state, snapshot)
          MODULES.each do |name|
            binding = state.fetch("bindings").fetch(name)
            selection = snapshot.fetch(name)
            unless binding.fetch("selection_epoch") ==
                   selection.fetch("epoch") &&
                   binding.fetch("active_selection") ==
                     selection.fetch("active")
              raise Hive::ConfigError,
                    "patrol module active selection changed"
            end
          end
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
          @repository.write_state_bytes(
            self.class.canonical(state)
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
