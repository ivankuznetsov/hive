require "digest"
require "time"
require "hive/modules/migration/live_bindings_resolver"
require "hive/modules/migration/patrol_evidence_verifier"

module Hive
  module Modules
    module Migration
      # Pure projection of lane bundles into the versioned migration report.
      # It validates evidence and derives every status/blocker; it owns no
      # filesystem path and performs no reads or writes.
      class ReportProjection
        def self.build(**attributes)
          new(**attributes).build
        end

        def initialize(lane_evidence:, reviewer:, reviewed_at:,
                       generated_at:, migration:,
                       live_bindings_resolver:)
          @reviewer = reviewer.to_s.strip
          @reviewed_at = Report.send(:timestamp, reviewed_at)
          @generated_at = Report.send(:timestamp, generated_at)
          @migration = Report.send(:normalize_migration, migration)
          @live_bindings_resolver =
            live_bindings_resolver ||
              LiveBindingsResolver.new(
                project_provider: nil,
                module_selections: nil,
                run_authority_provider: nil
              )
          @bundles = {}
          @verifications = {}
          normalize_lane_evidence(lane_evidence)
        end

        def build
          blockers = []
          lane_rows = Report::REQUIRED_LANES.to_h do |lane|
            entry = @verifications[lane]
            unless entry
              blockers << "#{lane}:lane_evidence_missing"
              next [
                lane,
                Report.send(:missing_lane_row)
              ]
            end
            verification = entry.fetch(:verification)
            verification.blockers.each do |blocker|
              blockers << "#{lane}:#{blocker}"
            end
            [
              lane,
              {
                "status" => verification.status,
                "blockers" => verification.blockers,
                "receipt_id" => verification.receipt.receipt_id,
                "effect_index_digest" =>
                  verification.effect_index.digest,
                "bundle_path" => entry.fetch(:bundle_path),
                "bundle_digest" => entry.fetch(:bundle_digest)
              }.freeze
            ]
          end.freeze
          blockers.concat(identity_blockers)
          blockers << "reviewer_signoff_missing" if @reviewer.empty?
          latest_review = @verifications.values.filter_map do |entry|
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
          status = if blockers.empty? &&
                      Report::REQUIRED_LANES.all? do |lane|
                        @verifications.dig(
                          lane, :verification
                        )&.verified?
                      end
            "evidence_ready_for_operator"
          else
            "evidence_required"
          end
          candidate, configurations, scenario = common_bindings
          body = {
            "schema" => Report::SCHEMA,
            "schema_version" => Report::SCHEMA_VERSION,
            "status" => status,
            "blockers" => blockers,
            "candidate" => candidate,
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
            verifications: @verifications.transform_values do |entry|
              entry.fetch(:verification)
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
          source.each do |lane_name, value|
            lane = lane_name.to_s
            next if value.nil?
            bundle = PatrolEvidence.immutable_json(
              value,
              label: "module migration report evidence"
            )
            unless Report.valid_bundle_shape?(bundle)
              PatrolEvidence.malformed!(
                "module migration report evidence"
              )
            end
            resolution = @live_bindings_resolver.resolve(
              receipt: bundle.fetch("receipt"),
              records: bundle.fetch("records")
            )
            verification = PatrolEvidenceVerifier.verify(
              receipt: bundle.fetch("receipt"),
              records: bundle.fetch("records"),
              current_bindings: resolution.bindings,
              binding_blockers: resolution.blockers
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
              bundle_path: relative,
              bundle_digest: digest
            }
          end
        rescue NoMethodError, TypeError
          PatrolEvidence.malformed!(
            "module migration report evidence"
          )
        end

        def identity_blockers
          return [] unless Report::REQUIRED_LANES.all? do |lane|
            @verifications.key?(lane)
          end

          deterministic = @verifications
            .fetch("deterministic")
            .fetch(:verification)
            .receipt
            .to_h
          installed = @verifications
            .fetch("installed")
            .fetch(:verification)
            .receipt
            .to_h
          blockers = []
          common_candidate_keys =
            PatrolEvidenceReceipt::CANDIDATE_KEYS -
              [ "installed_digest" ]
          blockers << "candidate_binding_mismatch" unless
            deterministic.fetch("candidate")
              .slice(*common_candidate_keys) ==
              installed.fetch("candidate")
                .slice(*common_candidate_keys)
          blockers << "installed_candidate_digest_missing" if
            installed.dig(
              "candidate", "installed_digest"
            ).nil?
          blockers << "mixed_run_evidence" unless
            deterministic.fetch("run_id") ==
              installed.fetch("run_id")
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

        def common_bindings
          preferred =
            @verifications["installed"] ||
            @verifications["deterministic"]
          return [
            nil,
            Report.send(
              :normalize_optional_configurations, nil
            ),
            nil
          ] unless preferred

          receipt = preferred.fetch(:verification).receipt.to_h
          [
            receipt.fetch("candidate"),
            receipt.fetch("configuration_digests"),
            receipt.fetch("scenario_manifest_digest")
          ]
        end
      end
    end
  end
end
