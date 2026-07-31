require "digest"
require "json"
require "hive/managed_directory"
require "hive/modules/migration/qualification_lane_result"
require "hive/modules/migration/qualification_run_descriptor"
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
        QUALIFICATION_ROOT = "qualification/runs".freeze
        MAX_STATE_BYTES = 512 * 1024
        MAX_REPORT_BYTES = 512 * 1024
        MAX_BUNDLE_BYTES = 16 * 1024 * 1024
        MAX_ARCHIVE_BYTES = 128 * 1024
        MAX_RECEIPT_BYTES = 16 * 1024
        MAX_QUALIFICATION_DESCRIPTOR_BYTES =
          QualificationRunDescriptor::MAX_BYTES
        MAX_QUALIFICATION_INPUT_BYTES = 256 * 1024 * 1024
        MAX_QUALIFICATION_TOTAL_BYTES = 512 * 1024 * 1024
        MAX_QUALIFICATION_FILES = 4_096
        MAX_QUALIFICATION_DEPTH = 32
        MAX_QUALIFICATION_RESULT_BYTES = 512 * 1024
        MAX_QUALIFICATION_DIAGNOSTICS = 256
        MAX_QUALIFICATION_REPRO_BYTES = 1024 * 1024
        MAX_QUALIFICATION_ARTIFACT_BYTES = 16 * 1024 * 1024
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
              anchor: existing_state_anchor(state_root)
            )
          end

          private

          def existing_state_anchor(state_root)
            File.lstat(state_root)
            state_root
          rescue Errno::ENOENT
            nil
          rescue SystemCallError
            state_root
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

        def import_qualification_run(descriptor_bytes:, inputs:)
          descriptor =
            QualificationRunDescriptor.load(descriptor_bytes)
          normalized = normalize_qualification_inputs(inputs)
          run_id = descriptor.run_id
          with_lock do
            normalized.each do |relative, entry|
              immutable_qualification_write(
                qualification_path(run_id, relative),
                entry.fetch(:bytes),
                mode: entry.fetch(:mode),
                max_bytes: MAX_QUALIFICATION_INPUT_BYTES,
                conflict:
                  "patrol qualification input conflicts with existing bytes"
              )
            end
            immutable_qualification_write(
              qualification_path(run_id, "descriptor.json"),
              descriptor_bytes,
              mode: 0o600,
              max_bytes: MAX_QUALIFICATION_DESCRIPTOR_BYTES,
              conflict:
                "patrol qualification descriptor conflicts with existing bytes"
            )
          end
          run_id
        end

        def qualification_descriptor(run_id, missing: false)
          run_id = qualification_run_id(run_id)
          with_lock(shared: true) do
            @directory.read(
              qualification_path(run_id, "descriptor.json"),
              max_bytes: MAX_QUALIFICATION_DESCRIPTOR_BYTES,
              missing: missing
            )
          end
        end

        def qualification_input(run_id, relative,
                                max_bytes: MAX_QUALIFICATION_INPUT_BYTES,
                                missing: false)
          relative = qualification_input_path(relative)
          with_lock(shared: true) do
            @directory.read(
              qualification_path(
                qualification_run_id(run_id), relative
              ),
              max_bytes: max_bytes,
              missing: missing
            )
          end
        end

        def qualification_input_snapshot(
          run_id, relative,
          max_bytes: MAX_QUALIFICATION_INPUT_BYTES,
          missing: false
        )
          relative = qualification_input_path(relative)
          with_lock(shared: true) do
            @directory.read_with_metadata(
              qualification_path(
                qualification_run_id(run_id), relative
              ),
              max_bytes: max_bytes,
              missing: missing
            )
          end
        end

        def qualification_input_entry_type(run_id, relative,
                                           missing: false)
          relative = qualification_input_path(
            relative, allow_directory: true
          )
          with_lock(shared: true) do
            @directory.entry_type(
              qualification_path(
                qualification_run_id(run_id), relative
              ),
              missing: missing
            )
          end
        end

        def each_qualification_input_child(run_id, relative)
          return enum_for(
            __method__, run_id, relative
          ) unless block_given?

          relative = qualification_input_path(
            relative, allow_directory: true
          )
          with_lock(shared: true) do
            @directory.each_child(
              qualification_path(
                qualification_run_id(run_id), relative
              )
            ) { |name| yield name }
          end
          nil
        end

        def publish_qualification_lane(
          run_id:, lane:, result_bytes:, bundle_bytes:, artifacts:,
          repro_json:, repro_script:
        )
          run_id = qualification_run_id(run_id)
          lane = qualification_lane_name(lane)
          descriptor_bytes =
            qualification_descriptor(run_id, missing: true)
          unless descriptor_bytes
            raise Hive::ConfigError,
                  "patrol qualification descriptor is missing"
          end
          descriptor =
            QualificationRunDescriptor.load(descriptor_bytes)
          refs = descriptor.artifact_refs(lane)
          artifacts = normalize_qualification_artifacts(artifacts)
          result_bytes = qualification_result_bytes(
            result_bytes, run_id: run_id, lane: lane
          )
          if QualificationLaneResult.load(result_bytes).blocked?
            raise Hive::ConfigError,
                  "patrol qualification blocked diagnostics are not terminal results"
          end
          with_lock do
            immutable_qualification_write(
              qualification_path(run_id, refs.fetch("bundle")),
              bounded_qualification_bytes!(
                bundle_bytes, MAX_BUNDLE_BYTES
              ),
              mode: 0o600,
              max_bytes: MAX_BUNDLE_BYTES,
              conflict:
                "patrol qualification lane conflicts with existing bytes"
            )
            artifacts.each do |relative, bytes|
              immutable_qualification_write(
                qualification_path(
                  run_id,
                  "#{refs.fetch('artifacts')}/#{relative}"
                ),
                bytes,
                mode: 0o600,
                max_bytes: MAX_QUALIFICATION_ARTIFACT_BYTES,
                conflict:
                  "patrol qualification lane conflicts with existing bytes"
              )
            end
            immutable_qualification_write(
              qualification_path(
                run_id, refs.fetch("repro_json")
              ),
              bounded_qualification_bytes!(
                repro_json, MAX_QUALIFICATION_REPRO_BYTES
              ),
              mode: 0o600,
              max_bytes: MAX_QUALIFICATION_REPRO_BYTES,
              conflict:
                "patrol qualification lane conflicts with existing bytes"
            )
            immutable_qualification_write(
              qualification_path(
                run_id, refs.fetch("repro_script")
              ),
              bounded_qualification_bytes!(
                repro_script, MAX_QUALIFICATION_REPRO_BYTES
              ),
              mode: 0o700,
              max_bytes: MAX_QUALIFICATION_REPRO_BYTES,
              conflict:
                "patrol qualification lane conflicts with existing bytes"
            )
            # Result is the completion sentinel and is therefore published
            # after every other immutable lane artifact.
            publish_qualification_lane_result(
              run_id: run_id,
              lane: lane,
              result_bytes: result_bytes
            )
          end
          refs
        end

        def publish_qualification_lane_result(
          run_id:, lane:, result_bytes:
        )
          run_id = qualification_run_id(run_id)
          lane = qualification_lane_name(lane)
          descriptor_bytes =
            qualification_descriptor(run_id, missing: true)
          unless descriptor_bytes
            raise Hive::ConfigError,
                  "patrol qualification descriptor is missing"
          end
          refs = QualificationRunDescriptor
            .load(descriptor_bytes)
            .artifact_refs(lane)
          result_bytes = qualification_result_bytes(
            result_bytes, run_id: run_id, lane: lane
          )
          if QualificationLaneResult.load(result_bytes).blocked?
            raise Hive::ConfigError,
                  "patrol qualification blocked diagnostics are not terminal results"
          end
          with_lock do
            immutable_qualification_write(
              qualification_path(run_id, refs.fetch("result")),
              result_bytes,
              mode: 0o600,
              max_bytes: MAX_QUALIFICATION_RESULT_BYTES,
              conflict:
                "patrol qualification lane result conflicts with existing bytes"
            )
          end
          refs.fetch("result")
        end

        # Blocked live-lane checks are retryable diagnostics, not completion
        # sentinels. Retain them append-only by content identity so a later
        # authorized attempt can still publish the one immutable result.
        def publish_qualification_lane_diagnostic(
          run_id:, lane:, result_bytes:
        )
          run_id = qualification_run_id(run_id)
          lane = qualification_lane_name(lane)
          descriptor_bytes =
            qualification_descriptor(run_id, missing: true)
          unless descriptor_bytes
            raise Hive::ConfigError,
                  "patrol qualification descriptor is missing"
          end
          refs = QualificationRunDescriptor
            .load(descriptor_bytes)
            .artifact_refs(lane)
          result_bytes = qualification_result_bytes(
            result_bytes, run_id: run_id, lane: lane
          )
          result = QualificationLaneResult.load(result_bytes)
          unless result.status == "blocked"
            raise Hive::ConfigError,
                  "patrol qualification lane diagnostic is malformed"
          end
          digest = Digest::SHA256.hexdigest(result_bytes)
          relative = File.join(
            File.dirname(refs.fetch("result")),
            "diagnostics",
            "#{digest}.json"
          )
          with_lock do
            immutable_qualification_write(
              qualification_path(run_id, relative),
              result_bytes,
              mode: 0o600,
              max_bytes: MAX_QUALIFICATION_RESULT_BYTES,
              conflict:
                "patrol qualification lane diagnostic conflicts with existing bytes"
            )
          end
          relative.freeze
        end

        def qualification_lane_diagnostics(run_id, lane)
          run_id = qualification_run_id(run_id)
          lane = qualification_lane_name(lane)
          descriptor_bytes =
            qualification_descriptor(run_id, missing: true)
          return [].freeze unless descriptor_bytes

          refs = QualificationRunDescriptor
            .load(descriptor_bytes)
            .artifact_refs(lane)
          root = File.join(
            File.dirname(refs.fetch("result")),
            "diagnostics"
          )
          names = with_lock(shared: true) do
            @directory.each_child(
              qualification_path(run_id, root),
              missing: true
            )&.to_a || []
          end
          unless
            names.length <= MAX_QUALIFICATION_DIAGNOSTICS &&
              names.all? do |name|
                name.match?(/\A[0-9a-f]{64}\.json\z/)
              end
            raise Hive::ConfigError,
                  "patrol qualification lane diagnostics are malformed"
          end
          names.sort.map do |name|
            bytes = qualification_run_file(
              run_id,
              "#{root}/#{name}",
              max_bytes: MAX_QUALIFICATION_RESULT_BYTES
            )
            unless
              Digest::SHA256.hexdigest(bytes) ==
                name.delete_suffix(".json")
              raise Hive::ConfigError,
                    "patrol qualification lane diagnostics are malformed"
            end
            result = QualificationLaneResult.load(bytes)
            unless
              result.run_id == run_id &&
                result.lane == lane &&
                result.status == "blocked"
              raise Hive::ConfigError,
                    "patrol qualification lane diagnostics are malformed"
            end
            result
          end.freeze
        rescue Hive::ConfigError
          raise
        rescue StandardError
          raise Hive::ConfigError,
                "patrol qualification lane diagnostics are malformed"
        end

        def qualification_lane_result(run_id, lane, missing: false)
          run_id = qualification_run_id(run_id)
          lane = qualification_lane_name(lane)
          descriptor_bytes =
            qualification_descriptor(run_id, missing: missing)
          return nil unless descriptor_bytes

          refs = QualificationRunDescriptor
            .load(descriptor_bytes)
            .artifact_refs(lane)
          qualification_run_file(
            run_id, refs.fetch("result"),
            max_bytes: MAX_QUALIFICATION_RESULT_BYTES,
            missing: missing
          )
        end

        def qualification_lane(run_id, lane, missing: false)
          run_id = qualification_run_id(run_id)
          lane = qualification_lane_name(lane)
          descriptor_bytes =
            qualification_descriptor(run_id, missing: missing)
          return nil unless descriptor_bytes

          refs = QualificationRunDescriptor
            .load(descriptor_bytes)
            .artifact_refs(lane)
          result = qualification_lane_result(
            run_id, lane, missing: true
          )
          return nil if result.nil? && missing
          unless result
            raise Hive::ConfigError,
                  "patrol qualification lane is missing"
          end
          files = {
            "result.json" => result,
            "bundle.json" => qualification_run_file(
              run_id, refs.fetch("bundle"),
              max_bytes: MAX_BUNDLE_BYTES
            ),
            "repro.json" => qualification_run_file(
              run_id, refs.fetch("repro_json"),
              max_bytes: MAX_QUALIFICATION_REPRO_BYTES
            ),
            "repro.sh" => qualification_run_file(
              run_id, refs.fetch("repro_script"),
              max_bytes: MAX_QUALIFICATION_REPRO_BYTES
            )
          }
          collect_qualification_artifacts(
            run_id, refs.fetch("artifacts"), files
          )
          files.freeze
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
            rebuilt = if live_bindings_resolver
              Report.build(
                run_id: payload.fetch("run_id"),
                lane_evidence: lane_evidence,
                reviewer: payload.fetch("reviewer"),
                reviewed_at: payload.fetch("reviewed_at"),
                generated_at: payload.fetch("generated_at"),
                migration: payload.fetch("migration"),
                live_bindings_resolver:
                  live_bindings_resolver
              )
            elsif lane_evidence.empty?
              Report.send(:loaded_evidence_required, payload)
            else
              raise Hive::ConfigError,
                    "module migration report requires live bindings"
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

        def normalize_qualification_inputs(inputs)
          unless inputs.is_a?(Hash) && !inputs.empty? &&
                 inputs.size <= MAX_QUALIFICATION_FILES
            raise Hive::ConfigError,
                  "patrol qualification inputs are malformed"
          end
          total = 0
          normalized = inputs.to_h do |relative, raw|
            relative = qualification_input_path(relative)
            unless raw.is_a?(Hash) &&
                   raw.keys.sort == %i[bytes mode]
              raise Hive::ConfigError,
                    "patrol qualification inputs are malformed"
            end
            bytes = bounded_qualification_bytes!(
              raw.fetch(:bytes), MAX_QUALIFICATION_INPUT_BYTES
            )
            mode = Integer(raw.fetch(:mode))
            unless [ 0o600, 0o700 ].include?(mode)
              raise Hive::ConfigError,
                    "patrol qualification inputs are malformed"
            end
            total += bytes.bytesize
            if total > MAX_QUALIFICATION_TOTAL_BYTES
              raise Hive::ConfigError,
                    "patrol qualification inputs exceed the bounded limit"
            end
            [ relative, { bytes: bytes, mode: mode }.freeze ]
          end
          normalized.freeze
        rescue ArgumentError, KeyError, TypeError
          raise Hive::ConfigError,
                "patrol qualification inputs are malformed"
        end

        def normalize_qualification_artifacts(artifacts)
          unless artifacts.is_a?(Hash) &&
                 artifacts.size <= MAX_QUALIFICATION_FILES
            raise Hive::ConfigError,
                  "patrol qualification artifacts are malformed"
          end
          total = 0
          artifacts.to_h do |relative, bytes|
            relative = safe_relative_path(
              relative,
              "patrol qualification artifact path"
            )
            if relative.split("/").length >
               MAX_QUALIFICATION_DEPTH
              raise Hive::ConfigError,
                    "patrol qualification artifacts exceed the bounded depth"
            end
            bytes = bounded_qualification_bytes!(
              bytes, MAX_QUALIFICATION_ARTIFACT_BYTES
            )
            total += bytes.bytesize
            if total > MAX_QUALIFICATION_TOTAL_BYTES
              raise Hive::ConfigError,
                    "patrol qualification artifacts exceed the bounded limit"
            end
            [ relative, bytes ]
          end.freeze
        end

        def qualification_run_id(value)
          text = value.to_s
          unless QualificationRunDescriptor::RUN_ID.match?(text)
            raise Hive::ConfigError,
                  "patrol qualification run id is malformed"
          end
          text
        end

        def qualification_lane_name(value)
          text = value.to_s
          unless QualificationRunDescriptor::LANES.include?(text)
            raise Hive::ConfigError,
                  "patrol qualification evidence lane is malformed"
          end
          text
        end

        def qualification_input_path(value, allow_directory: false)
          relative = safe_relative_path(
            value, "patrol qualification input path"
          )
          unless relative.start_with?("inputs/") &&
                 (allow_directory ||
                  !relative.end_with?("/"))
            raise Hive::ConfigError,
                  "patrol qualification input path is malformed"
          end
          relative
        end

        def qualification_path(run_id, relative)
          "#{QUALIFICATION_ROOT}/#{qualification_run_id(run_id)}/" \
            "#{safe_relative_path(relative, 'patrol qualification path')}"
        end

        def safe_relative_path(value, label)
          text = value.to_s
          parts = text.split("/", -1)
          unless !text.empty? && !text.start_with?("/") &&
                 !text.include?("\\") &&
                 parts.none? do |part|
                   part.empty? || part == "." || part == ".."
                 end
            raise Hive::ConfigError, "#{label} is malformed"
          end
          text
        end

        def bounded_qualification_bytes!(value, maximum)
          unless value.is_a?(String) &&
                 value.bytesize <= maximum
            raise Hive::ConfigError,
                  "patrol qualification bytes exceed the bounded limit"
          end
          value.b
        end

        def qualification_result_bytes(value, run_id:, lane:)
          qualification_run_id(run_id)
          qualification_lane_name(lane)
          bytes = bounded_qualification_bytes!(
            value, MAX_QUALIFICATION_RESULT_BYTES
          )
          result = QualificationLaneResult.load(bytes)
          unless result.run_id == run_id && result.lane == lane
            raise Hive::ConfigError,
                  "patrol qualification lane result authority changed"
          end
          bytes
        end

        def immutable_qualification_write(
          relative, bytes, mode:, max_bytes:, conflict:
        )
          existing = @directory.read_with_metadata(
            relative, max_bytes: max_bytes, missing: true
          )
          if existing &&
             (existing.fetch(:bytes) != bytes ||
              existing.fetch(:mode) != mode)
            raise Hive::ConfigError, conflict
          end
          @directory.atomic_write(
            relative, bytes, mode: mode
          ) unless existing
          relative
        end

        def qualification_run_file(run_id, relative,
                                   max_bytes:, missing: false)
          with_lock(shared: true) do
            @directory.read(
              qualification_path(run_id, relative),
              max_bytes: max_bytes,
              missing: missing
            )
          end
        end

        def collect_qualification_artifacts(
          run_id, root, result, relative = "",
          depth: 0, count: { value: 0 }
        )
          if depth > MAX_QUALIFICATION_DEPTH
            raise Hive::ConfigError,
                  "patrol qualification artifacts exceed the bounded depth"
          end
          path = relative.empty? ? root : "#{root}/#{relative}"
          children = with_lock(shared: true) do
            @directory.each_child(
              qualification_path(run_id, path),
              missing: true
            )&.to_a
          end
          return if children.nil?

          children.sort.each do |name|
            count[:value] += 1
            if count.fetch(:value) > MAX_QUALIFICATION_FILES
              raise Hive::ConfigError,
                    "patrol qualification artifacts exceed the bounded file count"
            end
            child_relative =
              relative.empty? ? name : "#{relative}/#{name}"
            child_path = "#{root}/#{child_relative}"
            type = with_lock(shared: true) do
              @directory.entry_type(
                qualification_path(run_id, child_path)
              )
            end
            if type == :directory
              collect_qualification_artifacts(
                run_id, root, result, child_relative,
                depth: depth + 1, count: count
              )
            else
              result["artifacts/#{child_relative}"] =
                qualification_run_file(
                  run_id, child_path,
                  max_bytes: MAX_QUALIFICATION_ARTIFACT_BYTES
                )
            end
          end
        end

        def bundle_path(relative)
          value = relative.to_s
          valid = value.match?(
            %r{\Areport-evidence/[0-9a-f]{64}\.json\z}
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
          payload.slice(
            "schema", "schema_version", "run_id", "reviewer",
            "reviewed_at", "generated_at", "migration"
          ).merge(
            "lanes" => payload.fetch("lanes").keys.sort
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
