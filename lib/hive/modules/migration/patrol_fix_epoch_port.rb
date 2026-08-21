require "hive/atomic_file"
require "hive/config"
require "hive/modules/migration/patrols"

module Hive
  module Modules
    module Migration
      # U9 adapter for the existing shared Patrol ownership epoch. It stores no
      # second generation: every transition is an idempotent rewrite of
      # Patrols' established epoch under that store's exclusive lock.
      class PatrolFixEpochPort
        SOURCE_MODULES = {
          "ordinary_patrol" => "patrol",
          "architecture_patrol" => "architecture-patrol"
        }.freeze

        def initialize(project_root:, hive_state_path: nil,
                       clock: -> { Time.now.utc })
          @project_root = File.expand_path(project_root)
          @hive_state_path = File.expand_path(
            hive_state_path || ".hive-state", @project_root
          )
          @clock = clock
        end

        def snapshot
          state = current_or_legacy
          SOURCE_MODULES.to_h { |source, _name| [ source, state.fetch("epoch") ] }
        end

        def ownership_snapshot
          state = current_or_legacy
          SOURCE_MODULES.to_h do |source, module_name|
            [ source, {
              "owner" => state.fetch("owners").fetch(module_name),
              "admission" => state.fetch("admissions").fetch(module_name)
            } ]
          end
        end

        def fence!(expected:, ownership:, inventory_guard:)
          transition(expected: expected, ownership: ownership) do |state, epoch, modes|
            already_fenced = state.fetch("epoch") == epoch + 1 &&
              owners_match?(state, modes) &&
              state.fetch("admissions").values.none?
            if already_fenced
              inventory_guard.call
              next state
            end
            assert_pre_transition!(state, epoch, modes)
            inventory_guard.call
            replacement = state.merge(
              "epoch" => epoch + 1,
              "admissions" => Patrols::MODULES.to_h { |name| [ name, false ] },
              "updated_at" => timestamp
            )
            write(replacement)
            replacement
          end.then { |state| epoch_map(state.fetch("epoch")) }
        end

        def activate_discovery!(expected:, ownership:)
          transition(expected: expected, ownership: ownership) do |state, epoch, modes|
            assert_epoch_and_owners!(state, epoch, modes)
            restored = admissions_for(modes)
            next state if state.fetch("admissions") == restored
            unless state.fetch("admissions").values.none?
              raise Hive::ConfigError,
                    "Patrol-fix discovery activation found mixed admissions"
            end
            replacement = state.merge(
              "admissions" => restored, "updated_at" => timestamp
            )
            write(replacement)
            replacement
          end.then { |state| epoch_map(state.fetch("epoch")) }
        end

        def rollback!(expected:, ownership:)
          transition(expected: expected, ownership: ownership) do |state, epoch, modes|
            restored = admissions_for(modes)
            already_restored = state.fetch("epoch") == epoch + 1 &&
              owners_match?(state, modes) && state.fetch("admissions") == restored
            next state if already_restored

            assert_epoch_and_owners!(state, epoch, modes)
            unless state.fetch("admissions").values.none?
              raise Hive::ConfigError,
                    "Patrol-fix rollback requires closed discovery admissions"
            end
            replacement = state.merge(
              "epoch" => epoch + 1, "admissions" => restored,
              "updated_at" => timestamp
            )
            write(replacement)
            replacement
          end.then { |state| epoch_map(state.fetch("epoch")) }
        end

        private

        def transition(expected:, ownership:)
          epoch = normalize_epoch(expected)
          modes = normalize_modes(ownership)
          Patrols.with_migration_lock(
            @project_root, hive_state_path: @hive_state_path, shared: false
          ) do
            state = Patrols.read_state(
              @project_root, hive_state_path: @hive_state_path
            ) || legacy_state
            yield state, epoch, modes
          end
        end

        def current_or_legacy
          Patrols.read_state(
            @project_root, hive_state_path: @hive_state_path
          ) || legacy_state
        end

        def assert_pre_transition!(state, epoch, modes)
          assert_epoch_and_owners!(state, epoch, modes)
          unless state.fetch("admissions") == admissions_for(modes)
            raise Hive::ConfigError,
                  "Patrol-fix source admissions changed before epoch fence"
          end
        end

        def assert_epoch_and_owners!(state, epoch, modes)
          unless state.fetch("epoch") == epoch && owners_match?(state, modes)
            raise Hive::ConfigError,
                  "Patrol-fix source ownership changed during cutover"
          end
        end

        def owners_match?(state, modes)
          SOURCE_MODULES.all? do |source, module_name|
            state.dig("owners", module_name) == modes.dig(source, "owner")
          end
        end

        def admissions_for(modes)
          SOURCE_MODULES.to_h do |source, module_name|
            [ module_name, modes.fetch(source).fetch("admission") ]
          end
        end

        def normalize_epoch(value)
          unless value.is_a?(Hash) && value.keys.sort == SOURCE_MODULES.keys.sort &&
                 value.values.all? { |item| item.is_a?(Integer) && item.positive? } &&
                 value.values.uniq.one?
            raise Hive::ConfigError, "Patrol-fix source epochs are inconsistent"
          end
          value.values.first
        end

        def normalize_modes(value)
          unless value.is_a?(Hash) && value.keys.sort == SOURCE_MODULES.keys.sort
            raise Hive::ConfigError, "Patrol-fix source ownership is inconsistent"
          end
          SOURCE_MODULES.to_h do |source, _module_name|
            mode = value.fetch(source)
            valid = mode.is_a?(Hash) && mode.keys.sort == %w[admission owner] &&
              %w[legacy module].include?(mode["owner"]) &&
              [ true, false ].include?(mode["admission"])
            unless valid
              raise Hive::ConfigError,
                    "Patrol-fix source ownership is inconsistent"
            end
            [ source, mode.slice("owner", "admission") ]
          end
        end

        def epoch_map(epoch)
          SOURCE_MODULES.to_h { |source, _module_name| [ source, epoch ] }
        end

        def legacy_state
          now = timestamp
          {
            "schema" => "hive-module-migration", "schema_version" => 1,
            "project" => File.basename(@project_root),
            "project_root" => @project_root, "epoch" => 1,
            "status" => "rolled_back",
            "owners" => Patrols::MODULES.to_h { |name| [ name, "legacy" ] },
            "admissions" => Patrols::MODULES.to_h { |name| [ name, true ] },
            "bindings" => {}, "blockers" => {}, "cutover_selections" => {},
            "watermarks" => {}, "shadow_started_at" => nil,
            "cutover_at" => nil, "rollback_at" => nil, "updated_at" => now
          }
        end

        def write(state)
          Patrols.validate_state!(state)
          Hive::AtomicFile.write(
            Patrols.state_file(
              @project_root, hive_state_path: @hive_state_path
            ),
            Patrols.canonical(state), mode: 0o600
          )
        end

        def timestamp = @clock.call.utc.iso8601(6)
      end
    end
  end
end
