require "digest"
require "fileutils"
require "json"
require "time"
require "hive/atomic_file"
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
          def migrate!(root:)
            new(root: root).migrate!
          end
        end

        def initialize(root:)
          @root = File.expand_path(root)
        end

        def migrate!
          return completed_result if File.file?(stamp_path)

          migrated = 0
          current = 0
          with_lock do
            return completed_result if File.file?(stamp_path)

            evidence_paths.each do |path|
              bytes = File.binread(path)
              data = JSON.parse(bytes)
              if data["schema_version"] == 2
                validate_v2!(path)
                current += 1
                next
              end

              validate_v1!(data, bytes)
              archive_v1!(data.fetch("module"), path, bytes)
              Hive::AtomicFile.write(path, canonical(v2_record(data, bytes)), mode: 0o600)
              Hive::AtomicFile.fsync_directory(File.dirname(path))
              migrated += 1
            end
            write_stamp(migrated: migrated, already_current: current)
          end
          Result.new(migrated: migrated, already_current: current)
        rescue Hive::ConfigError
          raise
        rescue JSON::ParserError, EncodingError, SystemCallError, IOError
          raise Hive::ConfigError, "module shadow v1 evidence migration failed"
        end

        private

        attr_reader :root

        def evidence_paths
          ShadowComparator::MODULES.flat_map do |module_name|
            Dir.glob(File.join(root, module_name, "*.json"))
          end.sort
        end

        def stamp_path
          File.join(root, "migrations", "shadow-decision-v2.json")
        end

        def completed_result
          bytes = File.binread(stamp_path)
          data = JSON.parse(bytes)
          expected = %w[already_current migrated schema schema_version status]
          valid = bytes == canonical(data) && data.keys.sort == expected &&
                  data["schema"] == "hive-module-shadow-decision-migration" &&
                  data["schema_version"] == 1 && data["status"] == "complete" &&
                  data["migrated"].is_a?(Integer) && data["migrated"] >= 0 &&
                  data["already_current"].is_a?(Integer) &&
                  data["already_current"] >= 0
          raise Hive::ConfigError, "module shadow v1 migration stamp is malformed" unless valid

          Result.new(
            migrated: 0,
            already_current: data.fetch("migrated") + data.fetch("already_current")
          )
        rescue JSON::ParserError, EncodingError, SystemCallError
          raise Hive::ConfigError, "module shadow v1 migration stamp is malformed"
        end

        def write_stamp(migrated:, already_current:)
          directory = File.dirname(stamp_path)
          FileUtils.mkdir_p(directory, mode: 0o700)
          Hive::AtomicFile.write(
            stamp_path,
            canonical(
              "schema" => "hive-module-shadow-decision-migration",
              "schema_version" => 1,
              "status" => "complete",
              "migrated" => migrated,
              "already_current" => already_current
            ),
            mode: 0o600
          )
          Hive::AtomicFile.fsync_directory(directory)
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
          record = ShadowComparator.new(root: root).records(module_name).find do |row|
            row["decision_id"] == decision_id
          end
          raise Hive::ConfigError, "module shadow evidence is malformed" unless record
        end

        def archive_v1!(module_name, path, bytes)
          directory = File.join(root, "archive", "v1", module_name)
          FileUtils.mkdir_p(directory, mode: 0o700)
          archive = File.join(directory, File.basename(path))
          if File.file?(archive)
            unless File.binread(archive) == bytes
              raise Hive::ConfigError,
                    "module shadow v1 archive conflicts with existing bytes"
            end
            return
          end

          Hive::AtomicFile.write(archive, bytes, mode: 0o600)
          Hive::AtomicFile.fsync_directory(directory)
        end

        def v2_record(data, bytes)
          trigger = {
            "archived_v1_trigger_digest" => data.fetch("trigger_digest")
          }
          {
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
        end

        def with_lock
          FileUtils.mkdir_p(root, mode: 0o700)
          File.open(File.join(root, "shadow-decision-migration.lock"),
                    File::RDWR | File::CREAT, 0o600) do |lock|
            lock.flock(File::LOCK_EX)
            yield
          ensure
            lock&.flock(File::LOCK_UN)
          end
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
