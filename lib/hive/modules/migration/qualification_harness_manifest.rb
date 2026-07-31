require "digest"
require "json"
require "open3"
require "pathname"
require "hive/errors"
require "hive/modules/migration/trusted_qualification_control"
require "hive/workflow_package/canonical_json"

module Hive
  module Modules
    module Migration
      # Verifies the committed trusted-computing-base inventory for Patrol
      # qualification. The manifest excludes itself; its exact bytes are
      # already bound by control.harness_manifest_sha256.
      class QualificationHarnessManifest
        PATH =
          "test/e2e/fixtures/patrol_qualification/" \
          "harness-manifest.json".freeze
        SCHEMA =
          "hive-patrol-qualification-harness-manifest".freeze
        SCHEMA_VERSION = 1
        TOP_LEVEL_KEYS = %w[files schema schema_version].freeze
        FILE_KEYS = %w[blob_oid mode path sha256 size].freeze
        MAX_FILES = 256
        MAX_FILE_BYTES = 4 * 1024 * 1024
        MAX_TOTAL_BYTES = 32 * 1024 * 1024
        BLOB_OID = /\A[0-9a-f]{40,64}\z/
        DIGEST = /\A[0-9a-f]{64}\z/
        REQUIRED_PATHS = %w[
          .github/workflows/patrol-qualification.yml
          lib/hive/modules/migration/candidate_execution_sandbox.rb
          lib/hive/modules/migration/live_bindings_resolver.rb
          lib/hive/modules/migration/patrol_evidence_verifier.rb
          lib/hive/modules/migration/qualification_harness_manifest.rb
          lib/hive/modules/migration/qualification_lane_runner.rb
          lib/hive/modules/migration/qualification_run_descriptor.rb
          lib/hive/modules/migration/qualification_scenario_oracle.rb
          lib/hive/modules/migration/qualification_scenario_process.rb
          lib/hive/modules/migration/qualification_target_inventory.rb
          lib/hive/modules/migration/trusted_qualification_control.rb
          packaging/patrol_evidence/candidate.rb
          schemas/hive-module-migration-report.v2.json
          schemas/hive-patrol-evidence-receipt.v1.json
          schemas/hive-patrol-qualification-run.v1.json
          test/e2e/lib/patrol_qualification_control_provider.rb
          test/e2e/lib/patrol_qualification_plan.rb
          test/e2e/lib/patrol_qualification_runner.rb
        ].freeze

        Result = Data.define(:payload, :sha256)
        Snapshot = Data.define(:bytes, :mode, :blob_oid)
        private_constant :Snapshot

        class << self
          def verify!(control:)
            new(control).call
          end
        end

        def initialize(control)
          unless control.is_a?(TrustedQualificationControl)
            malformed!
          end
          @control = control
          @root = control.checkout_root
          @commit_sha = control.payload.fetch("commit_sha")
        end

        def call
          verify_control_identity!
          manifest = committed_file(PATH)
          unless
            Digest::SHA256.hexdigest(manifest.bytes) ==
              @control.payload.fetch(
                "harness_manifest_sha256"
              )
            malformed!
          end
          payload = canonical_json(manifest.bytes)
          exact!(payload, TOP_LEVEL_KEYS)
          malformed! unless
            payload.fetch("schema") == SCHEMA &&
              payload.fetch("schema_version") == SCHEMA_VERSION
          rows = validate_rows(payload.fetch("files"))
          snapshots = verify_rows(rows)
          verify_required_closure!(rows, snapshots)
          Result.new(
            payload: immutable(payload),
            sha256:
              @control.payload.fetch(
                "harness_manifest_sha256"
              )
          ).freeze
        rescue JSON::ParserError, EncodingError, KeyError,
               NoMethodError, TypeError
          malformed!
        end

        private

        def validate_rows(value)
          malformed! unless
            value.is_a?(Array) &&
              !value.empty? &&
              value.length <= MAX_FILES
          rows = value.map do |row|
            exact!(row, FILE_KEYS)
            path = row.fetch("path")
            malformed! unless
              safe_path?(path) &&
                path != PATH &&
                row.fetch("mode").is_a?(String) &&
                row.fetch("mode") == "100644" &&
                row.fetch("blob_oid").is_a?(String) &&
                BLOB_OID.match?(row.fetch("blob_oid")) &&
                row.fetch("size").is_a?(Integer) &&
                row.fetch("size").between?(0, MAX_FILE_BYTES) &&
                row.fetch("sha256").is_a?(String) &&
                DIGEST.match?(row.fetch("sha256"))
            row
          end
          paths = rows.map { |row| row.fetch("path") }
          malformed! unless
            paths == paths.sort &&
              paths.uniq.length == paths.length &&
              rows.sum { |row| row.fetch("size") } <=
                MAX_TOTAL_BYTES
          rows.freeze
        end

        def verify_rows(rows)
          rows.to_h do |row|
            snapshot = committed_file(row.fetch("path"))
            malformed! unless
              snapshot.mode == row.fetch("mode") &&
                snapshot.blob_oid == row.fetch("blob_oid") &&
                snapshot.bytes.bytesize == row.fetch("size") &&
                Digest::SHA256.hexdigest(snapshot.bytes) ==
                  row.fetch("sha256")
            [ row.fetch("path"), snapshot ]
          end.freeze
        end

        def verify_required_closure!(rows, snapshots)
          paths = rows.map { |row| row.fetch("path") }
          malformed! unless
            (REQUIRED_PATHS - paths).empty?
          workflow = @control.payload.dig(
            "provenance", "workflow_path"
          )
          malformed! if workflow && !paths.include?(workflow)
          catalog_ref =
            @control.payload.dig("catalog", "ref")
          catalog = snapshots[catalog_ref]
          malformed! unless
            catalog &&
              Digest::SHA256.hexdigest(catalog.bytes) ==
                @control.payload.dig("catalog", "sha256")
          value = canonical_json(catalog.bytes)
          cases = value.fetch("cases")
          malformed! unless cases.is_a?(Array) && !cases.empty?
          root = File.dirname(catalog_ref)
          scenario_paths = cases.map do |row|
            malformed! unless row.is_a?(Hash)
            file = row.fetch("file")
            malformed! unless safe_path?(file)
            File.join(root, file)
          end
          malformed! unless
            scenario_paths.uniq.length == scenario_paths.length &&
              (scenario_paths - paths).empty?
        end

        def verify_control_identity!
          tree, _error, status =
            git("rev-parse", "#{@commit_sha}^{tree}")
          malformed! unless
            status.success? &&
              tree.strip ==
                @control.payload.fetch("tree_sha")
          return unless @control.trusted_remote?

          _output, _error, ancestor =
            git(
              "merge-base", "--is-ancestor",
              @commit_sha,
              @control.payload.fetch("ref")
            )
          malformed! unless ancestor.success?
        end

        def committed_file(path)
          output, _error, status =
            git("ls-tree", @commit_sha, "--", path)
          mode, type, blob_oid, actual_path =
            output.strip.split(/\s+/, 4)
          malformed! unless
            status.success? &&
              mode == "100644" &&
              type == "blob" &&
              BLOB_OID.match?(blob_oid.to_s) &&
              actual_path == path
          bytes, _show_error, show_status =
            git("show", "#{@commit_sha}:#{path}")
          malformed! unless show_status.success?
          Snapshot.new(
            bytes: bytes.b.freeze,
            mode: mode.freeze,
            blob_oid: blob_oid.freeze
          ).freeze
        end

        def git(*arguments)
          Open3.capture3(
            "git", *arguments,
            chdir: @root
          )
        rescue Errno::ENOENT, Errno::EACCES, Errno::ENOTDIR
          malformed!
        end

        def canonical_json(bytes)
          value = JSON.parse(bytes)
          malformed! unless
            bytes ==
              Hive::WorkflowPackage::CanonicalJSON.generate(value)
          value
        end

        def exact!(value, keys)
          malformed! unless
            value.is_a?(Hash) &&
              value.keys.all? { |key| key.is_a?(String) } &&
              value.keys.sort == keys
        end

        def safe_path?(value)
          return false unless value.is_a?(String)

          path = Pathname.new(value)
          !value.empty? &&
            value.bytesize <= 4_096 &&
            !path.absolute? &&
            path.cleanpath.to_s == value &&
            !value.include?("\\") &&
            !value.include?("\0") &&
            value.split("/").none? do |part|
              part.empty? || part == "." || part == ".."
            end
        rescue ArgumentError
          false
        end

        def immutable(value)
          case value
          when Hash
            value.to_h do |key, child|
              [ key.dup.freeze, immutable(child) ]
            end.freeze
          when Array
            value.map { |child| immutable(child) }.freeze
          when String
            value.dup.freeze
          when Integer, TrueClass, FalseClass, NilClass
            value
          else
            malformed!
          end
        end

        def malformed!
          raise Hive::ConfigError,
                "patrol qualification harness manifest is malformed"
        end
      end
    end
  end
end
