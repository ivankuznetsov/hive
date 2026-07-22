require "digest"
require "json"
require "time"
require "hive/atomic_file"
require "hive/config"
require "hive/module_package/managed_store"
require "hive/workflow_package/canonical_json"
require "hive/workflow_package/mutation_lock"

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
            return configured_shadow ? :shadow : :mutator unless state
            return :fenced unless state.fetch("admissions").fetch(module_name.to_s)

            state.fetch("owners").fetch(module_name.to_s) == "module" ? :mutator : :shadow
          rescue Hive::ConfigError, KeyError
            :fenced
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
            state = hive_state_path || File.join(File.expand_path(project_root), ".hive-state")
            File.join(File.expand_path(state), "module-runtime", "migration", "patrols.json")
          end

          def report_file(project_root, hive_state_path: nil)
            File.join(File.dirname(state_file(project_root, hive_state_path: hive_state_path)), "report.json")
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
        end

        attr_reader :project_root, :hive_state_path, :store

        def initialize(project_root:, project: nil, hive_state_path: nil, module_store: nil,
                       quiescence_probe: ->(_module_name, _root) { :ambiguous })
          @project_root = File.expand_path(project_root)
          @project = project || File.basename(@project_root)
          cfg = Hive::Config.load(@project_root)
          @hive_state_path = File.expand_path(hive_state_path || cfg.fetch("hive_state_path"))
          @store = module_store || Hive::ModulePackage::ManagedStore.new(@hive_state_path)
          @quiescence_probe = quiescence_probe
          @migration_dir = File.dirname(self.class.state_file(@project_root, hive_state_path: @hive_state_path))
        end

        def read = self.class.read_state(project_root, hive_state_path: hive_state_path)

        def adopt!(now: Time.now.utc)
          mutate do
            state = read || initial_state(now)
            if %w[shadowing module rolled_back].include?(state.fetch("status"))
              next outcome("already_current", state)
            end
            bindings = module_bindings
            pending = state.merge(
              "status" => "pending", "bindings" => bindings,
              "admissions" => MODULES.to_h { |name| [ name, false ] },
              "blockers" => {}, "updated_at" => timestamp(now)
            )
            write(pending)
            blockers = quiescence_blockers
            if blockers.empty?
              active = pending.merge(
                "status" => "shadowing",
                "admissions" => MODULES.to_h { |name| [ name, true ] },
                "blockers" => {}, "shadow_started_at" => pending["shadow_started_at"] || timestamp(now),
                "updated_at" => timestamp(now)
              )
              write(active)
              outcome("shadowing", active)
            else
              fenced = pending.merge("blockers" => blockers, "updated_at" => timestamp(now))
              write(fenced)
              outcome("pending", fenced, blockers)
            end
          end
        end

        def cutover!(report:, now: Time.now.utc)
          unless report.respond_to?(:eligible?) && report.eligible?
            blockers = report.respond_to?(:blockers) ? report.blockers : [ "report_invalid" ]
            raise Hive::ConfigError, "patrol module cutover evidence is incomplete: #{blockers.join(', ')}"
          end
          mutate do
            state = read or raise Hive::ConfigError, "patrol module migration has not been adopted"
            unless %w[shadowing cutover_pending rolled_back].include?(state.fetch("status"))
              raise Hive::ConfigError, "patrol module migration is not ready for cutover"
            end
            assert_report_bindings!(state, report)
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
          Hive::WorkflowPackage::MutationLock.with_lock(@migration_dir, &block)
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

        def assert_report_bindings!(state, report)
          report.configuration_digests.each do |name, digest_value|
            unless state.dig("bindings", name, "configuration_digest") == digest_value
              raise Hive::ConfigError, "patrol module shadow report configuration changed"
            end
          end
        end

        def restore_previous_selections(state, now)
          MODULES.to_h do |name|
            expected = state.fetch("cutover_selections").fetch(name)
            before = store.inspect_selection(name, include_tombstone: true)
            after = store.restore_previous(name, expected_active: expected, now: now)
            [ name, before.fetch("active") != after.fetch("active") ? "previous" : "no_previous" ]
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
