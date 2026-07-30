require "digest"
require "json"
require "hive/managed_directory"
require "hive/workflow_package/canonical_json"

module Hive
  module Modules
    module Migration
      # Descriptor-confined persistence and serialization for the Patrol
      # migration aggregate. Product state, report projections, immutable
      # evidence bundles, v1 archives, and migration receipts all share this
      # one lock and one verified directory anchor.
      class MigrationRepository
        LOCK_PATH = ".mutation.lock".freeze
        STATE_PATH = "patrols.json".freeze
        REPORT_PATH = "report.json".freeze
        INCOMING_BUNDLE_ROOT = "report-evidence/incoming".freeze
        MAX_STATE_BYTES = 512 * 1024
        MAX_REPORT_BYTES = 512 * 1024
        MAX_BUNDLE_BYTES = 16 * 1024 * 1024
        MAX_ARCHIVE_BYTES = 128 * 1024
        MAX_RECEIPT_BYTES = 16 * 1024
        EXPECTED_MISSING = :missing

        attr_reader :root

        class << self
          def for(project_root:, hive_state_path: nil)
            project_root = File.expand_path(project_root)
            state_root = File.expand_path(
              hive_state_path || ".hive-state",
              project_root
            )
            new(
              root: File.join(
                state_root, "module-runtime", "migration"
              ),
              anchor: state_root
            )
          end
        end

        def initialize(root:, anchor: nil)
          @root = File.expand_path(root).freeze
          anchor = File.expand_path(anchor) if anchor
          if anchor &&
             !@root.start_with?("#{anchor}#{File::SEPARATOR}")
            raise Hive::ConfigError,
                  "patrol module migration repository must be below its state anchor"
          end
          @directory = Hive::ManagedDirectory.new(
            root: @root,
            label: "patrol module migration repository",
            anchor: anchor
          )
          @lock_key =
            :"hive_patrol_migration_repository_#{Digest::SHA256.hexdigest(@root)}"
        end

        def state_path = File.join(root, STATE_PATH)
        def report_path = File.join(root, REPORT_PATH)

        def with_lock(shared: false)
          held = Thread.current[@lock_key]
          if held
            if held == :shared && !shared
              raise Hive::ConfigError,
                    "patrol module migration lock cannot be upgraded"
            end
            return yield
          end

          @directory.with_lock(LOCK_PATH, shared: shared) do
            Thread.current[@lock_key] = shared ? :shared : :exclusive
            yield
          ensure
            Thread.current[@lock_key] = nil
          end
        end

        def read_state_bytes
          with_lock(shared: true) do
            @directory.read(
              STATE_PATH,
              max_bytes: MAX_STATE_BYTES,
              missing: true
            )
          end
        end

        def write_state_bytes(bytes, expected_digest: nil)
          with_lock do
            @directory.atomic_write(
              STATE_PATH,
              bytes,
              mode: 0o600,
              expected_digest: expected_digest,
              max_existing_bytes:
                expected_digest && MAX_STATE_BYTES
            )
          end
        end

        def read_report_bytes(missing: false)
          with_lock(shared: true) do
            @directory.read(
              REPORT_PATH,
              max_bytes: MAX_REPORT_BYTES,
              missing: missing
            )
          end
        end

        def write_report_bytes(bytes, expected_digest: nil)
          with_lock do
            expected_missing =
              expected_digest == EXPECTED_MISSING
            @directory.atomic_write(
              REPORT_PATH,
              bytes,
              mode: 0o600,
              expected_digest:
                expected_missing ? nil : expected_digest,
              expected_absent: expected_missing,
              max_existing_bytes:
                expected_digest &&
                  !expected_missing &&
                  MAX_REPORT_BYTES
            )
          end
        end

        def read_bundle(relative, missing: false)
          relative = bundle_path(relative)
          with_lock(shared: true) do
            @directory.read(
              relative,
              max_bytes: MAX_BUNDLE_BYTES,
              missing: missing
            )
          end
        end

        def write_bundle(relative, bytes)
          relative = bundle_path(relative)
          verify_content_bundle_identity!(relative, bytes)
          with_lock do
            existing = @directory.read(
              relative,
              max_bytes: MAX_BUNDLE_BYTES,
              missing: true
            )
            if existing && existing != bytes
              raise Hive::ConfigError,
                    "module migration report evidence conflicts with existing bytes"
            end
            @directory.atomic_write(
              relative, bytes, mode: 0o600
            ) unless existing
            relative
          end
        end

        def incoming_bundle(lane)
          unless %w[deterministic installed].include?(lane.to_s)
            raise Hive::ConfigError,
                  "patrol qualification evidence lane is malformed"
          end
          read_bundle(
            "#{INCOMING_BUNDLE_ROOT}/#{lane}.json",
            missing: true
          )
        end

        def incoming_bundles
          require "hive/modules/migration/report"

          with_lock(shared: true) do
            Report::REQUIRED_LANES.each_with_object({}) do |lane, result|
              bytes = @directory.read(
                "#{INCOMING_BUNDLE_ROOT}/#{lane}.json",
                max_bytes: MAX_BUNDLE_BYTES,
                missing: true
              )
              next unless bytes

              payload = JSON.parse(bytes)
              unless bytes == canonical(payload) &&
                     Report.valid_bundle_shape?(payload)
                raise Hive::ConfigError,
                      "patrol qualification evidence is malformed"
              end
              result[lane] = payload
            end.freeze
          end
        rescue JSON::ParserError, EncodingError
          raise Hive::ConfigError,
                "patrol qualification evidence is malformed"
        end

        def write_report(report, expected_digest: nil)
          require "hive/modules/migration/report"
          unless report.is_a?(Report)
            raise Hive::ConfigError,
                  "module migration report is malformed"
          end

          with_lock do
            report.send(:bundle_bytes).each do |relative, bytes|
              write_bundle(relative, bytes)
            end
            write_report_bytes(
              Report.canonical(report.payload),
              expected_digest: expected_digest
            )
            prune_unreferenced_bundles!(report)
          end
          report
        end

        def load_report(live_bindings_resolver: nil)
          require "hive/modules/migration/report"

          with_lock(shared: true) do
            bytes = @directory.read(
              REPORT_PATH,
              max_bytes: MAX_REPORT_BYTES
            )
            payload = JSON.parse(bytes)
            unless bytes == Report.canonical(payload) &&
                   Report.valid_payload?(payload)
              raise Hive::ConfigError,
                    "module migration report is malformed"
            end
            lane_evidence =
              payload.fetch("lanes").each_with_object({}) do |(lane, row), result|
                relative = row.fetch("bundle_path")
                next unless relative

                bundle_bytes = @directory.read(
                  bundle_path(relative),
                  max_bytes: MAX_BUNDLE_BYTES
                )
                unless Digest::SHA256.hexdigest(bundle_bytes) ==
                       row.fetch("bundle_digest")
                  raise Hive::ConfigError,
                        "module migration report evidence digest changed"
                end
                bundle = JSON.parse(bundle_bytes)
                unless bundle_bytes == Report.canonical(bundle) &&
                       Report.valid_bundle_shape?(bundle)
                  raise Hive::ConfigError,
                        "module migration report evidence is malformed"
                end
                result[lane] = bundle
              end
            rebuilt = if lane_evidence.empty?
              Report.send(:loaded_evidence_required, payload)
            else
              Report.build(
                lane_evidence: lane_evidence,
                reviewer: payload.fetch("reviewer"),
                reviewed_at: payload.fetch("reviewed_at"),
                generated_at: payload.fetch("generated_at"),
                migration: payload.fetch("migration"),
                live_bindings_resolver:
                  live_bindings_resolver
              )
            end
            unless Report.canonical(rebuilt.payload) == bytes
              if live_bindings_resolver &&
                 stable_report_identity(rebuilt.payload) ==
                   stable_report_identity(payload)
                next rebuilt
              end
              raise Hive::ConfigError,
                    "module migration report evidence is stale"
            end
            rebuilt
          end
        rescue JSON::ParserError, EncodingError
          raise Hive::ConfigError,
                "module migration report is missing or unreadable"
        end

        def read_archive(relative, missing: false)
          with_lock(shared: true) do
            @directory.read(
              archive_path(relative),
              max_bytes: MAX_ARCHIVE_BYTES,
              missing: missing
            )
          end
        end

        def write_archive(relative, bytes)
          relative = archive_path(relative)
          with_lock do
            existing = @directory.read(
              relative,
              max_bytes: MAX_ARCHIVE_BYTES,
              missing: true
            )
            if existing && existing != bytes
              raise Hive::ConfigError,
                    "legacy module migration report archive conflicts with existing bytes"
            end
            @directory.atomic_write(
              relative, bytes, mode: 0o600
            ) unless existing
            relative
          end
        end

        def read_receipt(relative, missing: false)
          with_lock(shared: true) do
            @directory.read(
              receipt_path(relative),
              max_bytes: MAX_RECEIPT_BYTES,
              missing: missing
            )
          end
        end

        def write_receipt(relative, bytes)
          relative = receipt_path(relative)
          with_lock do
            existing = @directory.read(
              relative,
              max_bytes: MAX_RECEIPT_BYTES,
              missing: true
            )
            if existing && existing != bytes
              raise Hive::ConfigError,
                    "module migration report migration receipt conflicts"
            end
            @directory.atomic_write(
              relative, bytes, mode: 0o600
            ) unless existing
            relative
          end
        end

        private

        def bundle_path(relative)
          value = relative.to_s
          valid = value.match?(
            %r{\Areport-evidence/(?:incoming/(?:deterministic|installed)\.json|[0-9a-f]{64}\.json)\z}
          )
          raise Hive::ConfigError,
                "module migration report evidence path is malformed" unless
            valid
          value
        end

        def archive_path(relative)
          value = relative.to_s
          unless value.match?(
            %r{\Aarchive/report-v1/[0-9a-f]{64}\.json\z}
          )
            raise Hive::ConfigError,
                  "module migration report archive path is malformed"
          end
          value
        end

        def receipt_path(relative)
          value = relative.to_s
          unless value == "migrations/report-v2.json"
            raise Hive::ConfigError,
                  "module migration report receipt path is malformed"
          end
          value
        end

        def canonical(value)
          Hive::WorkflowPackage::CanonicalJSON.generate(value)
        end

        def stable_report_identity(payload)
          payload.reject do |key, _value|
            %w[blockers report_id status].include?(key)
          end.merge(
            "lanes" => payload.fetch("lanes").to_h do |lane, row|
              [
                lane,
                row.reject do |key, _value|
                  %w[blockers status].include?(key)
                end
              ]
            end
          )
        end

        def verify_content_bundle_identity!(relative, bytes)
          match = relative.match(
            %r{\Areport-evidence/([0-9a-f]{64})\.json\z}
          )
          return unless match
          return if Digest::SHA256.hexdigest(bytes) == match[1]

          raise Hive::ConfigError,
                "module migration report evidence identity is malformed"
        end

        def prune_unreferenced_bundles!(report)
          referenced = report.payload.fetch("lanes").values.filter_map do |row|
            row.fetch("bundle_path")
          end
          @directory.each_child(
            "report-evidence",
            missing: true
          ) do |name|
            next unless name.match?(/\A[0-9a-f]{64}\.json\z/)

            relative = "report-evidence/#{name}"
            next if referenced.include?(relative)

            @directory.unlink(
              relative,
              expected_digest: name.delete_suffix(".json"),
              max_bytes: MAX_BUNDLE_BYTES
            )
          end
        end
      end
    end
  end
end
