require "digest"
require "json"
require "time"
require "hive/managed_directory"
require "hive/modules/migration/bounded_file_inventory"
require "hive/modules/migration/shadow_comparator"
require "hive/workflow_package/canonical_json"

module Hive
  module Modules
    module Migration
      # Explicit one-off conversion. Runtime comparison reads v2 only; this is
      # the sole place allowed to understand the retired digest-only v1 shape.
      class ShadowDecisionMigration
        Result = Data.define(:migrated, :already_current)
        V1_KEYS = %w[
          comparable configuration_digest decision_id duplicate_effects
          evidence_source explained_differences legacy legacy_effects module
          module_decision module_effects occurred_at recorded_at schema
          schema_version trigger_digest unexplained_differences
        ].freeze

        class << self
          def migrate!(root:, quiescence_probe: -> { :ambiguous })
            new(root: root, quiescence_probe: quiescence_probe).migrate!
          end

          def ensure_complete!(root:)
            new(
              root: root,
              quiescence_probe: nil
            ).ensure_complete!
          end
        end

        def initialize(root:, quiescence_probe:)
          @root = File.expand_path(root)
          @quiescence_probe = quiescence_probe
          @managed_directory = Hive::ManagedDirectory.new(
            root: @root,
            label: "module shadow migration"
          )
          @lock_directory = Hive::ManagedDirectory.new(
            root: File.dirname(@root),
            label: "module migration lock"
          )
        end

        def migrate!
          migrated = 0
          current = 0
          with_lock do
            unless @quiescence_probe.call.to_sym == :quiescent
              raise Hive::ConfigError,
                    "module shadow v1 evidence migration requires quiescence"
            end
            stamp = bounded_read(stamp_path, missing: true)
            return completed_result(bytes: stamp) if stamp

            evidence_paths.each do |path|
              bytes = bounded_read(path)
              data = JSON.parse(bytes)
              if data["schema_version"] == 2
                validate_v2!(path)
                checkpoint!(path, bytes, "current")
                current += 1
                next
              end

              validate_v1!(data, bytes)
              checkpoint!(path, bytes, "pending")
              archive_v1!(data.fetch("module"), path, bytes)
              @managed_directory.atomic_write(
                @managed_directory.relative_path(path),
                canonical(v2_record(data, bytes)),
                mode: 0o600
              )
              checkpoint!(path, bytes, "migrated")
              migrated += 1
            end
            validate_zero_v1!
            write_stamp(migrated: migrated, already_current: current)
            complete_checkpoint!
          end
          Result.new(migrated: migrated, already_current: current)
        rescue Hive::ConfigError
          raise
        rescue JSON::ParserError, EncodingError, SystemCallError, IOError
          raise Hive::ConfigError, "module shadow v1 evidence migration failed"
        end

        def ensure_complete!
          @lock_directory.with_lock(
            ".mutation.lock", shared: true
          ) { completed_result }
        end

        private

        attr_reader :root

        def evidence_paths
          return enum_for(__method__) unless block_given?

          inventories = ShadowComparator::MODULES.sort.to_h do |module_name|
            inventory = evidence_inventory(module_name)
            [ module_name, [ inventory, inventory.snapshot ] ]
          end
          total = inventories.values.sum { |_inventory, snapshot| snapshot.count }
          if total > ShadowComparator::MAX_RECORDS
            raise Hive::ConfigError,
                  "module shadow evidence exceeds the bounded read limit"
          end
          inventories.each do |module_name, (inventory, snapshot)|
            inventory.each_name(
              page_size: ShadowComparator::MAX_PAGE_SIZE,
              snapshot: snapshot
            ) do |filename|
              yield File.join(root, module_name, filename)
            end
          end
          nil
        end

        def stamp_path
          File.join(root, "migrations", "shadow-decision-v2.json")
        end

        def checkpoint_path
          File.join(root, "migrations", "shadow-decision-v2-checkpoint.json")
        end

        def completed_result(bytes: nil)
          bytes ||= bounded_read(stamp_path)
          data = JSON.parse(bytes)
          expected = %w[already_current migrated schema schema_version status]
          valid = bytes == canonical(data) && data.keys.sort == expected &&
                  data["schema"] == "hive-module-shadow-decision-migration" &&
                  data["schema_version"] == 1 && data["status"] == "complete" &&
                  data["migrated"].is_a?(Integer) && data["migrated"] >= 0 &&
                  data["already_current"].is_a?(Integer) &&
                  data["already_current"] >= 0
          raise Hive::ConfigError, "module shadow v1 migration stamp is malformed" unless valid
          validate_zero_v1!

          Result.new(
            migrated: 0,
            already_current: data.fetch("migrated") + data.fetch("already_current")
          )
        rescue JSON::ParserError, EncodingError, SystemCallError
          raise Hive::ConfigError, "module shadow v1 migration stamp is malformed"
        end

        def write_stamp(migrated:, already_current:)
          @managed_directory.atomic_write(
            @managed_directory.relative_path(stamp_path),
            canonical(
              "schema" => "hive-module-shadow-decision-migration",
              "schema_version" => 1,
              "status" => "complete",
              "migrated" => migrated,
              "already_current" => already_current
            ),
            mode: 0o600
          )
        end

        def validate_v1!(data, bytes)
          valid = data.is_a?(Hash) &&
                  data.keys.sort == V1_KEYS &&
                  bytes == canonical(data) &&
                  data["schema"] == "hive-module-shadow-decision" &&
                  data["schema_version"] == 1 &&
                  ShadowComparator::MODULES.include?(data["module"]) &&
                  data["decision_id"].to_s.match?(/\A[0-9a-f]{64}\z/) &&
                  data["trigger_digest"].to_s.match?(/\A[0-9a-f]{64}\z/) &&
                  data["configuration_digest"].to_s.match?(/\A[0-9a-f]{64}\z/) &&
                  [ true, false ].include?(data["comparable"]) &&
                  (data["evidence_source"].nil? ||
                   data["evidence_source"] == "legacy_mutator_capture") &&
                  %w[
                    duplicate_effects explained_differences legacy_effects
                    module_effects unexplained_differences
                  ].all? { |key| data[key].is_a?(Array) }
          Time.iso8601(data.fetch("occurred_at"))
          Time.iso8601(data.fetch("recorded_at"))
          raise Hive::ConfigError, "module shadow v1 evidence is malformed" unless valid
        rescue ArgumentError, TypeError, KeyError, NoMethodError
          raise Hive::ConfigError, "module shadow v1 evidence is malformed"
        end

        def validate_v2!(path)
          module_name = File.basename(File.dirname(path))
          decision_id = File.basename(path, ".json")
          bytes = bounded_read(path)
          data = JSON.parse(bytes)
          unless bytes == canonical(data)
            raise Hive::ConfigError, "module shadow evidence is malformed"
          end
          ShadowComparator.new(root: root).validate_record!(
            data,
            expected_module: module_name,
            expected_decision_id: decision_id
          )
        end

        def archive_v1!(module_name, path, bytes)
          directory = File.join(root, "archive", "v1", module_name)
          archive = File.join(directory, File.basename(path))
          existing = bounded_read(archive, missing: true)
          if existing
            unless existing == bytes
              raise Hive::ConfigError,
                    "module shadow v1 archive conflicts with existing bytes"
            end
            return
          end

          @managed_directory.atomic_write(
            @managed_directory.relative_path(archive),
            bytes,
            mode: 0o600
          )
        end

        def v2_record(data, bytes)
          trigger = {
            "archived_v1_trigger_digest" => data.fetch("trigger_digest")
          }
          record = {
            "schema" => "hive-module-shadow-decision",
            "schema_version" => 2,
            "module" => data.fetch("module"),
            "decision_id" => data.fetch("decision_id"),
            "trigger" => trigger,
            "trigger_digest" => digest(trigger),
            "occurred_at" => data.fetch("occurred_at"),
            "recorded_at" => data.fetch("recorded_at"),
            "evidence_source" => "archived_v1",
            "configuration_digest" => data.fetch("configuration_digest"),
            "comparable" => false,
            "legacy_capture" => nil,
            "module_decision" => data.fetch("module_decision"),
            "explained_differences" => data.fetch("explained_differences"),
            "unexplained_differences" => data.fetch("unexplained_differences"),
            "legacy_effects" => [],
            "module_effects" => [],
            "duplicate_effects" => [],
            "migration" => {
              "source_digest" => ::Digest::SHA256.hexdigest(bytes),
              "source_schema_version" => 1,
              "status" => "archived_non_comparable"
            }
          }
          record["semantic_digest"] = digest(
            record.reject { |key, _value| key == "recorded_at" }
          )
          record
        end

        def with_lock
          @lock_directory.with_lock(
            ".mutation.lock", shared: false
          ) { yield }
        end

        def validate_zero_v1!
          evidence_paths.each do |path|
            bytes = bounded_read(path)
            data = JSON.parse(bytes)
            unless data["schema_version"] == 2
              raise Hive::ConfigError,
                    "module shadow v1 evidence remains after migration"
            end
            validate_v2!(path)
          end
        rescue JSON::ParserError, EncodingError
          raise Hive::ConfigError, "module shadow v1 evidence migration failed"
        end

        def checkpoint!(path, source_bytes, status)
          checkpoint = read_checkpoint
          relative = path.delete_prefix("#{root}/")
          entry = {
            "source_digest" => ::Digest::SHA256.hexdigest(source_bytes),
            "status" => status
          }
          existing = checkpoint.fetch("files")[relative]
          if existing && existing["source_digest"] != entry.fetch("source_digest") &&
             existing["status"] != "migrated"
            raise Hive::ConfigError,
                  "module shadow v1 migration inventory changed"
          end
          checkpoint.fetch("files")[relative] = entry
          @managed_directory.atomic_write(
            @managed_directory.relative_path(checkpoint_path),
            canonical(checkpoint),
            mode: 0o600
          )
        end

        def read_checkpoint
          bytes = bounded_read(checkpoint_path, missing: true)
          return {
            "schema" => "hive-module-shadow-decision-migration-checkpoint",
            "schema_version" => 1,
            "status" => "in_progress",
            "files" => {}
          } unless bytes

          data = JSON.parse(bytes)
          valid = bytes == canonical(data) &&
                  data.is_a?(Hash) &&
                  data.keys.sort == %w[files schema schema_version status] &&
                  data["schema"] ==
                    "hive-module-shadow-decision-migration-checkpoint" &&
                  data["schema_version"] == 1 &&
                  %w[in_progress complete].include?(data["status"]) &&
                  data["files"].is_a?(Hash)
          unless valid
            raise Hive::ConfigError,
                  "module shadow v1 migration checkpoint is malformed"
          end
          data
        rescue JSON::ParserError, EncodingError
          raise Hive::ConfigError,
                "module shadow v1 migration checkpoint is malformed"
        end

        def complete_checkpoint!
          checkpoint = read_checkpoint.merge("status" => "complete")
          @managed_directory.atomic_write(
            @managed_directory.relative_path(checkpoint_path),
            canonical(checkpoint),
            mode: 0o600
          )
        end

        def evidence_inventory(module_name)
          Hive::Modules::Migration::BoundedFileInventory.new(
            directory: @managed_directory,
            relative: module_name,
            filename_pattern: /\A[0-9a-f]{64}\.json\z/,
            max_entries: ShadowComparator::MAX_RECORDS,
            cursor_prefix: "shadow-migration-v1",
            malformed_message:
              "module shadow v1 evidence migration failed",
            overflow_message:
              "module shadow evidence exceeds the bounded read limit",
            missing: true
          )
        end

        def bounded_read(path, missing: false)
          @managed_directory.read(
            @managed_directory.relative_path(path),
            max_bytes: ShadowComparator::MAX_RECORD_BYTES,
            missing: missing
          )
        rescue Hive::ConfigError
          raise Hive::ConfigError,
                "module shadow v1 evidence migration failed"
        end

        def canonical(value)
          Hive::WorkflowPackage::CanonicalJSON.generate(value)
        end

        def digest(value)
          ::Digest::SHA256.hexdigest(canonical(value))
        end
      end
    end
  end
end
