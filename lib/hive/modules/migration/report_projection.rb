require "hive/modules/migration/patrol_qualification"

module Hive
  module Modules
    module Migration
      class ReportProjection < Data.define(
        :report_id, :generated_at, :candidate_sha,
        :scenario_manifest_digest, :status, :lanes, :blockers,
        :supersedes, :migration
      )
        SCHEMA = "hive-module-migration-report".freeze
        SCHEMA_VERSION = 2
        MAX_BYTES = 128 * 1024
        LANES = %w[deterministic installed_live].freeze
        KEYS = %w[
          blockers candidate_sha generated_at lanes migration report_id schema
          schema_version scenario_manifest_digest status supersedes
        ].freeze
        MIGRATION_KEYS = %w[
          archive_digest disposition source_digest source_schema_version
        ].freeze

        class << self
          def build(qualifications:, generated_at:, migration: nil,
                    supersedes: nil)
            qualifications = Array(qualifications).map do |value|
              coerce_qualification(value)
            end
            malformed! if qualifications.size > LANES.size
            grouped = qualifications.to_h { |value| [ value.lane, value ] }
            malformed! unless grouped.size == qualifications.size
            malformed! if qualifications.empty? && migration.nil?
            candidate_sha, scenario_digest = common_binding(qualifications)
            lanes = LANES.to_h { |lane| [ lane, grouped[lane] ] }.freeze
            blockers = lane_blockers(lanes)
            status = if qualifications.any? { |value| value.status == "invalidated" }
              "invalidated"
            elsif qualifications.size == LANES.size &&
                  qualifications.all?(&:qualified?)
              "qualified"
            else
              "evidence_required"
            end
            migration = migration_value(migration)
            malformed! if qualifications.empty? &&
                          migration.fetch("disposition") != "evidence_required"
            attributes = {
              generated_at: PatrolEvidence.timestamp(
                generated_at, label: "module migration report v2"
              ),
              candidate_sha: candidate_sha,
              scenario_manifest_digest: scenario_digest,
              status: status.freeze,
              lanes: lanes,
              blockers: blockers,
              supersedes: optional_id(supersedes, "report"),
              migration: migration
            }
            create(attributes)
          rescue KeyError, NoMethodError, TypeError
            malformed!
          end

          def from_h(value)
            value = PatrolEvidence.immutable_json(
              value, label: "module migration report v2"
            )
            PatrolEvidence.exact_keys!(
              value, KEYS, label: "module migration report v2"
            )
            malformed! unless value["schema"] == SCHEMA &&
                              value["schema_version"] == SCHEMA_VERSION
            lane_values = value.fetch("lanes")
            PatrolEvidence.exact_keys!(
              lane_values, LANES, label: "module migration report v2"
            )
            report = build(
              qualifications: LANES.filter_map do |lane|
                qualification = lane_values[lane]
                qualification && PatrolQualification.from_h(qualification)
              end,
              generated_at: value["generated_at"],
              migration: value["migration"],
              supersedes: value["supersedes"]
            )
            unless PatrolEvidence.canonical(report.to_h) ==
                   PatrolEvidence.canonical(value)
              raise Hive::ConfigError,
                    "module migration report v2 identity does not match its contents"
            end
            report
          rescue KeyError, NoMethodError, TypeError
            malformed!
          end

          def merge(existing:, qualification:, generated_at:)
            existing = existing.is_a?(self) ?
              from_h(existing.to_h) : from_h(existing)
            qualification = coerce_qualification(qualification)
            current = existing.lanes.fetch(qualification.lane)
            return existing if current&.qualification_id ==
                               qualification.qualification_id
            if current
              replacement = current.qualified? &&
                qualification.status == "invalidated" &&
                qualification.supersedes == current.qualification_id
              unless replacement
                raise Hive::ConfigError,
                      "module migration report lane is already complete"
              end
            end

            build(
              qualifications: existing.lanes.filter_map do |lane, value|
                lane == qualification.lane ? qualification : value
              end,
              generated_at: generated_at,
              migration: existing.migration,
              supersedes: existing.report_id
            )
          end

          private

          def create(attributes)
            report = new(
              report_id: PatrolEvidence.digest("report", payload(attributes)),
              **attributes
            )
            PatrolEvidence.bounded!(
              report.to_h,
              max_bytes: MAX_BYTES,
              label: "module migration report v2"
            )
            report
          end

          def payload(attributes, report_id: nil)
            {
              "schema" => SCHEMA,
              "schema_version" => SCHEMA_VERSION,
              "report_id" => report_id,
              "generated_at" => attributes.fetch(:generated_at),
              "candidate_sha" => attributes.fetch(:candidate_sha),
              "scenario_manifest_digest" =>
                attributes.fetch(:scenario_manifest_digest),
              "status" => attributes.fetch(:status),
              "lanes" => attributes.fetch(:lanes).transform_values do |value|
                value&.to_h
              end.freeze,
              "blockers" => attributes.fetch(:blockers),
              "supersedes" => attributes.fetch(:supersedes),
              "migration" => attributes.fetch(:migration)
            }.tap { |result| result.delete("report_id") unless report_id }
          end

          def coerce_qualification(value)
            value.is_a?(PatrolQualification) ?
              PatrolQualification.from_h(value.to_h) :
              PatrolQualification.from_h(value)
          rescue Hive::ConfigError
            malformed!
          end

          def common_binding(values)
            return [ nil, nil ] if values.empty?
            candidates = values.map(&:candidate_sha).uniq
            scenarios = values.map(&:scenario_manifest_digest).uniq
            malformed! unless candidates.one? && scenarios.one?
            [ candidates.first, scenarios.first ]
          end

          def lane_blockers(lanes)
            lanes.flat_map do |lane, qualification|
              if qualification.nil?
                [ "#{lane}:evidence_required" ]
              else
                qualification.blockers.map do |blocker|
                  "#{lane}:#{blocker}"
                end
              end
            end.uniq.sort.freeze
          end

          def migration_value(value)
            return nil if value.nil?
            PatrolEvidence.exact_keys!(
              value, MIGRATION_KEYS, label: "module migration report v2"
            )
            malformed! unless value["source_schema_version"] == 1 &&
                              %w[projected evidence_required].include?(
                                value["disposition"].to_s
                              )
            source_digest = digest(value["source_digest"])
            archive_digest = digest(value["archive_digest"])
            malformed! unless source_digest == archive_digest
            {
              "source_schema_version" => 1,
              "source_digest" => source_digest,
              "archive_digest" => archive_digest,
              "disposition" => value["disposition"].to_s.freeze
            }.freeze
          end

          def optional_id(value, prefix)
            return nil if value.nil?
            string = value.to_s
            malformed! unless string.match?(
              /\A#{Regexp.escape(prefix)}-[0-9a-f]{64}\z/
            )
            string.dup.freeze
          end

          def digest(value)
            string = value.to_s
            malformed! unless string.match?(/\A[0-9a-f]{64}\z/)
            string.dup.freeze
          end

          def malformed!
            raise Hive::ConfigError, "module migration report v2 is malformed"
          end
        end

        def eligible? = status == "qualified"

        def configuration_digests
          qualification = lanes["installed_live"] || lanes["deterministic"]
          qualification ? qualification.configuration_digests : {}
        end

        def payload = to_h

        def to_h
          self.class.send(
            :payload,
            {
              generated_at: generated_at,
              candidate_sha: candidate_sha,
              scenario_manifest_digest: scenario_manifest_digest,
              status: status,
              lanes: lanes,
              blockers: blockers,
              supersedes: supersedes,
              migration: migration
            },
            report_id: report_id
          ).freeze
        end
      end
    end
  end
end
