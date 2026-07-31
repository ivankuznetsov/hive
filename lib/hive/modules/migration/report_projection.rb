require "digest"
require "time"
require "hive/modules/migration/live_bindings_resolver"
require "hive/modules/migration/patrol_evidence_verifier"
require "hive/modules/migration/qualification_run_descriptor"

module Hive
  module Modules
    module Migration
      # Pure projection of one explicitly selected qualification run. Lane
      # failures and blockers remain typed all the way to the report instead
      # of being flattened into generic evidence requirements.
      class ReportProjection
        STATUS_RANK = {
          "verified" => 0,
          "evidence_required" => 1,
          "blocked" => 2,
          "failed" => 3
        }.freeze

        def self.build(**attributes)
          new(**attributes).build
        end

        def initialize(run_id:, lane_evidence:, reviewer:, reviewed_at:,
                       generated_at:, migration:,
                       live_bindings_resolver:)
          @run_id = run_id.to_s
          unless QualificationRunDescriptor::RUN_ID.match?(@run_id)
            PatrolEvidence.malformed!(
              "module migration report run"
            )
          end
          unless live_bindings_resolver.respond_to?(:resolve)
            raise Hive::ConfigError,
                  "module migration report requires live bindings"
          end
          @reviewer = reviewer.to_s.strip
          @reviewed_at = Report.send(:timestamp, reviewed_at)
          @generated_at = Report.send(:timestamp, generated_at)
          @migration = Report.send(:normalize_migration, migration)
          @live_bindings_resolver = live_bindings_resolver
          @bundles = {}
          @verifications = {}
          normalize_lane_evidence(lane_evidence)
        end

        def build
          blockers = []
          lane_rows = Report::REQUIRED_LANES.to_h do |lane|
            entry = @verifications.fetch(lane)
            verification = entry[:verification]
            lane_blockers = if verification
              verification.blockers
            else
              entry.fetch(:resolution).issues
            end
            lane_blockers.each do |blocker|
              blockers << "#{lane}:#{blocker}"
            end
            row = if verification
              {
                "status" => verification.status,
                "blockers" => verification.blockers,
                "receipt_id" => verification.receipt.receipt_id,
                "effect_index_digest" =>
                  verification.effect_index.digest,
                "bundle_path" => entry.fetch(:bundle_path),
                "bundle_digest" => entry.fetch(:bundle_digest)
              }.freeze
            else
              unresolved_lane_row(entry.fetch(:resolution))
            end
            [ lane, row ]
          end.freeze
          blockers.concat(identity_blockers)
          blockers << "reviewer_signoff_missing" if @reviewer.empty?
          latest_review = @verifications.values.filter_map do |entry|
            next unless entry[:verification]

            Time.iso8601(
              entry.fetch(:verification)
                .receipt
                .to_h
                .fetch("reviewed_at")
            )
          end.max
          blockers << "review_predates_evidence" if
            latest_review &&
              Time.iso8601(@reviewed_at) < latest_review
          blockers = blockers.uniq.sort.freeze
          status = report_status(lane_rows, blockers)
          candidate, control, configurations, scenario =
            common_bindings
          body = {
            "schema" => Report::SCHEMA,
            "schema_version" => Report::SCHEMA_VERSION,
            "run_id" => @run_id,
            "status" => status,
            "blockers" => blockers,
            "candidate" => candidate,
            "control" => control,
            "configuration_digests" => configurations,
            "scenario_manifest_digest" => scenario,
            "lanes" => lane_rows,
            "reviewer" => @reviewer,
            "reviewed_at" => @reviewed_at,
            "generated_at" => @generated_at,
            "migration" => @migration
          }
          Report.send(
            :from_projection,
            body,
            bundles: @bundles,
            verifications: @verifications.each_with_object({}) do |(lane, entry), result|
              verification = entry[:verification]
              result[lane] = verification if verification
            end
          )
        end

        private

        def normalize_lane_evidence(source)
          source = source.to_h
          unknown =
            source.keys.map(&:to_s) - Report::REQUIRED_LANES
          PatrolEvidence.malformed!(
            "module migration report"
          ) unless unknown.empty?
          Report::REQUIRED_LANES.each do |lane|
            value = source[lane] || source[lane.to_sym]
            receipt, records = raw_evidence(value)
            resolution = @live_bindings_resolver.resolve(
              run_id: @run_id,
              lane: lane,
              receipt: receipt,
              records: records
            )
            if value.nil? ||
               resolution.blocked? ||
               resolution.failed?
              @verifications[lane] = {
                resolution: resolution
              }.freeze
              next
            end
            bundle = PatrolEvidence.immutable_json(
              value,
              label: "module migration report evidence"
            )
            unless Report.valid_bundle_shape?(bundle)
              PatrolEvidence.malformed!(
                "module migration report evidence"
              )
            end
            verification = PatrolEvidenceVerifier.verify(
              receipt: bundle.fetch("receipt"),
              records: bundle.fetch("records"),
              resolution: resolution
            )
            unless verification.receipt.lane == lane
              PatrolEvidence.malformed!(
                "module migration report evidence"
              )
            end
            bytes = Report.canonical(bundle)
            if bytes.bytesize > Report::MAX_BUNDLE_BYTES
              PatrolEvidence.malformed!(
                "module migration report evidence"
              )
            end
            digest = Digest::SHA256.hexdigest(bytes)
            relative = "report-evidence/#{digest}.json"
            @bundles[relative] = bytes
            @verifications[lane] = {
              verification: verification,
              resolution: resolution,
              bundle_path: relative,
              bundle_digest: digest
            }.freeze
          end
        rescue NoMethodError, TypeError
          PatrolEvidence.malformed!(
            "module migration report evidence"
          )
        end

        def raw_evidence(value)
          return [ nil, nil ] if value.nil?
          return [ value, value ] unless value.is_a?(Hash)

          [
            value["receipt"] || value[:receipt],
            value["records"] || value[:records]
          ]
        end

        def unresolved_lane_row(resolution)
          if resolution.status == "evidence_required" &&
             resolution.issues == [ "lane_evidence_missing" ]
            return Report.send(:missing_lane_row)
          end

          {
            "status" => resolution.status,
            "blockers" => resolution.issues,
            "receipt_id" => nil,
            "effect_index_digest" => nil,
            "bundle_path" => nil,
            "bundle_digest" => nil
          }.freeze
        end

        def report_status(lane_rows, blockers)
          lane_status = lane_rows.values.map do |row|
            row.fetch("status")
          end.max_by do |status|
            STATUS_RANK.fetch(status)
          end
          case lane_status
          when "failed" then "failed"
          when "blocked" then "blocked"
          when "evidence_required" then "evidence_required"
          else
            blockers.empty? ?
              "evidence_ready_for_operator" :
              "evidence_required"
          end
        end

        def identity_blockers
          return [] unless Report::REQUIRED_LANES.all? do |lane|
            @verifications.key?(lane)
          end
          deterministic = authority_for("deterministic")
          installed = authority_for("installed")
          return [] unless deterministic && installed

          blockers = []
          blockers << "candidate_binding_mismatch" unless
            deterministic.fetch("candidate") ==
              installed.fetch("candidate")
          blockers << "control_binding_mismatch" unless
            deterministic.fetch("control") ==
              installed.fetch("control")
          blockers << "mixed_run_evidence" unless
            deterministic.fetch("run_id") ==
              installed.fetch("run_id") &&
              deterministic.fetch("run_id") == @run_id
          blockers << "configuration_binding_mismatch" unless
            deterministic.fetch("configuration_digests") ==
              installed.fetch("configuration_digests")
          blockers << "project_binding_mismatch" unless
            deterministic.fetch("project") ==
              installed.fetch("project")
          blockers << "module_selection_binding_mismatch" unless
            deterministic.fetch("module_selections") ==
              installed.fetch("module_selections")
          blockers << "scenario_manifest_binding_mismatch" unless
            deterministic.fetch("scenario_manifest_digest") ==
              installed.fetch("scenario_manifest_digest")
          blockers
        end

        def authority_for(lane)
          @verifications
            .dig(lane, :resolution)
            &.bindings
        end

        def common_bindings
          authority =
            authority_for("installed") ||
            authority_for("deterministic")
          return [
            nil,
            nil,
            Report.send(
              :normalize_optional_configurations, nil
            ),
            nil
          ] unless authority

          [
            authority.fetch("candidate"),
            authority.fetch("control"),
            authority.fetch("configuration_digests"),
            authority.fetch("scenario_manifest_digest")
          ]
        end
      end
    end
  end
end
