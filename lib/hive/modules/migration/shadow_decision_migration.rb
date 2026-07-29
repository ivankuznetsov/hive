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
        CHECKPOINT_SCHEMA =
          "hive-module-shadow-decision-migration-checkpoint".freeze
        CHECKPOINT_VERSION = 2
        CHECKPOINT_ENTRY_PATTERN =
          /\A(?:architecture-patrol|patrol)\/[0-9a-f]{64}\.json\z/
        CHECKPOINT_DIGEST = /\A[0-9a-f]{64}\z/
        MAX_CHECKPOINT_BYTES = 4 * 1024 * 1024
        MAX_STAMP_BYTES = 16 * 1024

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
          with_lock do
            unless @quiescence_probe.call.to_sym == :quiescent
              raise Hive::ConfigError,
                    "module shadow v1 evidence migration requires quiescence"
            end
            paths = evidence_paths.to_a
            stamp = bounded_read(
              stamp_path, missing: true, max_bytes: MAX_STAMP_BYTES
            )
            if stamp
              next completed_result(
                bytes: stamp, paths: paths, repair_checkpoint: true
              )
            end

            checkpoint = prepared_checkpoint(paths)
            paths.each do |path|
              bytes = bounded_read(path)
              data = JSON.parse(bytes)
              if data["schema_version"] == 2
                checkpoint = resume_v2!(checkpoint, path, bytes)
                next
              end

              validate_v1!(data, bytes, path: path)
              relative = relative_path(path)
              entry = checkpoint.fetch("files").fetch(relative)
              unless entry.fetch("status") == "pending" &&
                     entry == pending_entry(data, bytes)
                inventory_changed!
              end
              archive_v1!(relative, bytes)
              verify_archive!(path, entry, expected_bytes: bytes)
              replacement = canonical(v2_record(data, bytes))
              @managed_directory.atomic_write(
                relative,
                replacement,
                mode: 0o600,
                expected_digest: sha256(bytes),
                max_existing_bytes: ShadowComparator::MAX_RECORD_BYTES
              )
              verify_migrated_entry!(path, entry)
              checkpoint = transition_checkpoint!(
                checkpoint, relative, entry.merge("status" => "migrated")
              )
            end
            counts = validate_terminal_checkpoint!(checkpoint, paths)
            validate_zero_v1!(paths)
            write_stamp(
              migrated: counts.fetch(:migrated),
              already_current: counts.fetch(:current)
            )
            complete_checkpoint!(checkpoint)
            Result.new(
              migrated: counts.fetch(:migrated),
              already_current: counts.fetch(:current)
            )
          end
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

        def completed_result(bytes: nil, paths: nil, repair_checkpoint: false)
          bytes ||= bounded_read(
            stamp_path, max_bytes: MAX_STAMP_BYTES
          )
          data = JSON.parse(bytes)
          expected = %w[already_current migrated schema schema_version status]
          valid = data.is_a?(Hash) &&
                  bytes == canonical(data) && data.keys.sort == expected &&
                  data["schema"] == "hive-module-shadow-decision-migration" &&
                  data["schema_version"] == 1 && data["status"] == "complete" &&
                  data["migrated"].is_a?(Integer) && data["migrated"] >= 0 &&
                  data["already_current"].is_a?(Integer) &&
                  data["already_current"] >= 0
          raise Hive::ConfigError, "module shadow v1 migration stamp is malformed" unless valid
          paths ||= evidence_paths.to_a
          validate_zero_v1!(paths)
          raw_checkpoint = read_checkpoint
          checkpoint_members = checkpoint_paths(raw_checkpoint)
          checkpoint, upgraded = normalized_checkpoint(
            raw_checkpoint, checkpoint_members
          )
          counts = validate_terminal_checkpoint!(
            checkpoint, checkpoint_members
          )
          unless counts.fetch(:migrated) == data.fetch("migrated") &&
                 counts.fetch(:current) == data.fetch("already_current")
            raise Hive::ConfigError,
                  "module shadow v1 migration stamp is malformed"
          end
          if repair_checkpoint
            write_checkpoint(checkpoint) if upgraded
            complete_checkpoint!(checkpoint) unless
              checkpoint.fetch("status") == "complete"
          elsif checkpoint.fetch("status") != "complete"
            raise Hive::ConfigError,
                  "module shadow v1 migration checkpoint is incomplete"
          end

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

        def validate_v1!(data, bytes, path: nil)
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
          if path
            valid &&=
              data["module"] == File.basename(File.dirname(path)) &&
              data["decision_id"] == File.basename(path, ".json")
          end
          Time.iso8601(data.fetch("occurred_at"))
          Time.iso8601(data.fetch("recorded_at"))
          raise Hive::ConfigError, "module shadow v1 evidence is malformed" unless valid
        rescue ArgumentError, TypeError, KeyError, NoMethodError
          raise Hive::ConfigError, "module shadow v1 evidence is malformed"
        end

        def validate_v2!(path, bytes: nil)
          module_name = File.basename(File.dirname(path))
          decision_id = File.basename(path, ".json")
          bytes ||= bounded_read(path)
          data = JSON.parse(bytes)
          unless bytes == canonical(data)
            raise Hive::ConfigError, "module shadow evidence is malformed"
          end
          ShadowComparator.new(root: root).validate_record!(
            data,
            expected_module: module_name,
            expected_decision_id: decision_id
          )
          data
        end

        def archive_v1!(relative, bytes)
          archive = File.join(root, archive_relative(relative))
          existing = bounded_read(archive, missing: true)
          if existing
            unless existing == bytes
              raise Hive::ConfigError,
                    "module shadow v1 archive conflicts with existing bytes"
            end
            return
          end

          @managed_directory.atomic_write(
            archive_relative(relative),
            bytes,
            mode: 0o600
          )
        end

        def v2_record(data, bytes)
          trigger = {
            "kind" => "archived_v1",
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

        def validate_zero_v1!(expected_paths = nil)
          paths = evidence_paths.to_a
          assert_inventory_paths!(paths, expected_paths) if expected_paths
          paths.each do |path|
            bytes = bounded_read(path)
            data = JSON.parse(bytes)
            unless data["schema_version"] == 2
              raise Hive::ConfigError,
                      "module shadow v1 evidence remains after migration"
            end
            validate_v2!(path, bytes: bytes)
          end
        rescue JSON::ParserError, EncodingError
          raise Hive::ConfigError, "module shadow v1 evidence migration failed"
        end

        def prepared_checkpoint(paths)
          checkpoint = read_checkpoint
          unless checkpoint
            checkpoint = build_checkpoint(paths)
            write_checkpoint(checkpoint)
            return checkpoint
          end

          checkpoint, upgraded = normalized_checkpoint(checkpoint, paths)
          if checkpoint.fetch("status") == "complete"
            raise Hive::ConfigError,
                  "module shadow v1 migration checkpoint is complete " \
                  "without a completion stamp"
          end
          write_checkpoint(checkpoint) if upgraded
          checkpoint
        end

        def build_checkpoint(paths)
          {
            "schema" => CHECKPOINT_SCHEMA,
            "schema_version" => CHECKPOINT_VERSION,
            "status" => "in_progress",
            "files" => paths.to_h do |path|
              [ relative_path(path), checkpoint_entry(path) ]
            end
          }
        end

        def checkpoint_entry(path)
          bytes = bounded_read(path)
          data = JSON.parse(bytes)
          case data["schema_version"]
          when 1
            validate_v1!(data, bytes, path: path)
            pending_entry(data, bytes)
          when 2
            validate_v2!(path, bytes: bytes)
            inventory_changed! if data["migration"]
            current_entry(bytes)
          else
            raise Hive::ConfigError,
                  "module shadow v1 evidence migration failed"
          end
        end

        def pending_entry(data, source_bytes)
          source_digest = sha256(source_bytes)
          {
            "status" => "pending",
            "source_digest" => source_digest,
            "archive_digest" => source_digest,
            "v2_digest" => sha256(
              canonical(v2_record(data, source_bytes))
            )
          }
        end

        def current_entry(bytes)
          {
            "status" => "current",
            "v2_digest" => sha256(bytes)
          }
        end

        def migrated_entry(path, data, bytes)
          relative = relative_path(path)
          source = bounded_read(
            File.join(root, archive_relative(relative))
          )
          source_data = JSON.parse(source)
          validate_v1!(source_data, source, path: path)
          entry = pending_entry(source_data, source).merge(
            "status" => "migrated"
          )
          unless data.dig("migration", "source_digest") ==
                   entry.fetch("source_digest") &&
                 sha256(bytes) == entry.fetch("v2_digest") &&
                 bytes == canonical(v2_record(source_data, source))
            inventory_changed!
          end
          entry
        end

        def resume_v2!(checkpoint, path, bytes)
          data = validate_v2!(path, bytes: bytes)
          relative = relative_path(path)
          entry = checkpoint.fetch("files").fetch(relative)
          case entry.fetch("status")
          when "current"
            unless data["migration"].nil? &&
                   entry.fetch("v2_digest") == sha256(bytes)
              inventory_changed!
            end
            checkpoint
          when "pending"
            verify_migrated_entry!(path, entry, bytes: bytes, data: data)
            transition_checkpoint!(
              checkpoint, relative, entry.merge("status" => "migrated")
            )
          when "migrated"
            verify_migrated_entry!(path, entry, bytes: bytes, data: data)
            checkpoint
          end
        end

        def verify_migrated_entry!(path, entry, bytes: nil, data: nil)
          unless %w[pending migrated].include?(entry.fetch("status")) &&
                 entry.fetch("source_digest") ==
                   entry.fetch("archive_digest")
            checkpoint_malformed!
          end
          source = verify_archive!(path, entry)
          source_data = JSON.parse(source)
          bytes ||= bounded_read(path)
          data ||= validate_v2!(path, bytes: bytes)
          replacement = canonical(v2_record(source_data, source))
          valid = sha256(replacement) == entry.fetch("v2_digest") &&
                  sha256(bytes) == entry.fetch("v2_digest") &&
                  bytes == replacement &&
                  data.dig("migration", "source_digest") ==
                    entry.fetch("source_digest")
          inventory_changed! unless valid
          true
        end

        def verify_archive!(path, entry, expected_bytes: nil)
          relative = relative_path(path)
          source = bounded_read(
            File.join(root, archive_relative(relative))
          )
          source_data = JSON.parse(source)
          validate_v1!(source_data, source, path: path)
          source_digest = sha256(source)
          valid = source_digest == entry.fetch("source_digest") &&
                  source_digest == entry.fetch("archive_digest") &&
                  (!expected_bytes || source == expected_bytes)
          inventory_changed! unless valid
          source
        rescue JSON::ParserError, EncodingError
          inventory_changed!
        end

        def transition_checkpoint!(checkpoint, relative, replacement)
          checkpoint.fetch("files")[relative] = replacement
          write_checkpoint(checkpoint)
          checkpoint
        end

        def normalized_checkpoint(checkpoint, paths)
          checkpoint_malformed! unless checkpoint
          if checkpoint.fetch("schema_version") == CHECKPOINT_VERSION
            assert_inventory_paths!(paths, checkpoint_paths(checkpoint))
            return [ checkpoint, false ]
          end

          entries = checkpoint.fetch("files")
          expected = paths.to_h { |path| [ relative_path(path), path ] }
          inventory_changed! unless (entries.keys - expected.keys).empty?
          normalized = expected.to_h do |relative, path|
            legacy = entries[relative]
            [ relative, normalize_legacy_entry(path, legacy) ]
          end
          [
            checkpoint.merge(
              "schema_version" => CHECKPOINT_VERSION,
              "files" => normalized
            ),
            true
          ]
        end

        def normalize_legacy_entry(path, entry)
          return checkpoint_entry(path) unless entry

          bytes = bounded_read(path)
          data = JSON.parse(bytes)
          case entry.fetch("status")
          when "current"
            validate_v2!(path, bytes: bytes)
            if data["migration"]
              inventory_changed! unless
                entry.fetch("source_digest") == sha256(bytes)
              migrated_entry(path, data, bytes)
            else
              inventory_changed! unless
                entry.fetch("source_digest") == sha256(bytes)
              current_entry(bytes)
            end
          when "pending"
            normalized = if data["schema_version"] == 1
              validate_v1!(data, bytes, path: path)
              pending_entry(data, bytes)
            else
              validate_v2!(path, bytes: bytes)
              migrated_entry(path, data, bytes).merge("status" => "pending")
            end
            inventory_changed! unless
              normalized.fetch("source_digest") ==
                entry.fetch("source_digest")
            normalized
          when "migrated"
            validate_v2!(path, bytes: bytes)
            migrated_entry(path, data, bytes).tap do |normalized|
              inventory_changed! unless
                normalized.fetch("source_digest") ==
                  entry.fetch("source_digest")
            end
          end
        end

        def validate_terminal_checkpoint!(checkpoint, paths)
          assert_inventory_paths!(paths, checkpoint_paths(checkpoint))
          counts = { migrated: 0, current: 0 }
          checkpoint.fetch("files").each do |relative, entry|
            path = File.join(root, relative)
            case entry.fetch("status")
            when "migrated"
              verify_migrated_entry!(path, entry)
              counts[:migrated] += 1
            when "current"
              bytes = bounded_read(path)
              data = validate_v2!(path, bytes: bytes)
              inventory_changed! unless
                data["migration"].nil? &&
                entry.fetch("v2_digest") == sha256(bytes)
              counts[:current] += 1
            else
              raise Hive::ConfigError,
                    "module shadow v1 migration checkpoint is incomplete"
            end
          end
          counts
        end

        def read_checkpoint
          bytes = bounded_read(
            checkpoint_path,
            missing: true,
            max_bytes: MAX_CHECKPOINT_BYTES
          )
          return nil unless bytes

          data = JSON.parse(bytes)
          valid = bytes == canonical(data) &&
                  data.is_a?(Hash) &&
                  data.keys.sort == %w[files schema schema_version status] &&
                  data["schema"] == CHECKPOINT_SCHEMA &&
                  [ 1, CHECKPOINT_VERSION ].include?(
                    data["schema_version"]
                  ) &&
                  %w[in_progress complete].include?(data["status"]) &&
                  data["files"].is_a?(Hash) &&
                  data["files"].all? do |relative, entry|
                    valid_checkpoint_entry?(
                      relative, entry, version: data["schema_version"]
                    )
                  end
          checkpoint_malformed! unless valid
          data
        rescue JSON::ParserError, EncodingError
          checkpoint_malformed!
        end

        def valid_checkpoint_entry?(relative, entry, version:)
          return false unless relative.is_a?(String) &&
                              CHECKPOINT_ENTRY_PATTERN.match?(relative) &&
                              entry.is_a?(Hash)
          if version == 1
            return entry.keys.sort == %w[source_digest status] &&
                   %w[current migrated pending].include?(entry["status"]) &&
                   CHECKPOINT_DIGEST.match?(entry["source_digest"].to_s)
          end

          case entry["status"]
          when "current"
            entry.keys.sort == %w[status v2_digest] &&
              CHECKPOINT_DIGEST.match?(entry["v2_digest"].to_s)
          when "pending", "migrated"
            entry.keys.sort == %w[
              archive_digest source_digest status v2_digest
            ] &&
              %w[archive_digest source_digest v2_digest].all? do |key|
                CHECKPOINT_DIGEST.match?(entry[key].to_s)
              end
          else
            false
          end
        end

        def write_checkpoint(checkpoint)
          bytes = canonical(checkpoint)
          if bytes.bytesize > MAX_CHECKPOINT_BYTES
            raise Hive::ConfigError,
                  "module shadow v1 migration checkpoint exceeds the " \
                  "bounded write limit"
          end
          @managed_directory.atomic_write(
            relative_path(checkpoint_path),
            bytes,
            mode: 0o600
          )
        end

        def complete_checkpoint!(checkpoint)
          completed = checkpoint.merge("status" => "complete")
          write_checkpoint(completed)
          completed
        end

        def assert_inventory_paths!(paths, expected)
          actual = paths.map { |path| relative_path(path) }.sort
          anticipated = expected.map { |path| relative_path(path) }.sort
          inventory_changed! unless actual == anticipated
        end

        def checkpoint_paths(checkpoint)
          checkpoint_malformed! unless checkpoint

          checkpoint.fetch("files").keys.map do |relative|
            File.join(root, relative)
          end
        end

        def archive_relative(relative)
          File.join("archive", "v1", relative)
        end

        def relative_path(path)
          @managed_directory.relative_path(path)
        end

        def inventory_changed!
          raise Hive::ConfigError,
                "module shadow v1 migration inventory changed"
        end

        def checkpoint_malformed!
          raise Hive::ConfigError,
                "module shadow v1 migration checkpoint is malformed"
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

        def bounded_read(
          path,
          missing: false,
          max_bytes: ShadowComparator::MAX_RECORD_BYTES
        )
          @managed_directory.read(
            @managed_directory.relative_path(path),
            max_bytes: max_bytes,
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

        def sha256(bytes)
          ::Digest::SHA256.hexdigest(bytes)
        end
      end
    end
  end
end
