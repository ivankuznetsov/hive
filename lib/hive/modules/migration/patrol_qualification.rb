require "time"
require "hive/modules/migration/patrol_effect_index"
require "hive/modules/migration/patrol_evidence_verifier"

module Hive
  module Modules
    module Migration
      class PatrolQualification < Data.define(
        :qualification_id, :lane, :run_id, :candidate_sha,
        :catalog_digest, :source_digest, :manifest_digest,
        :scenario_manifest_digest, :status, :receipt_ids,
        :decision_replay_count, :modules, :effect_count,
        :effect_replay_count, :duplicate_effects, :unsettled_effects,
        :elapsed_seconds, :blockers, :supersedes, :contradiction,
        :generated_at
      )
        LANES = %w[deterministic installed_live].freeze
        STATUSES = %w[qualified evidence_required invalidated].freeze
        MAX_RECEIPTS = 4_096
        MIN_DECISIONS = 10
        MIN_DECISION_CLASSES = 2
        MIN_REPOSITORIES = 2
        MIN_CHANGE_WINDOWS = 2
        KEYS = %w[
          blockers candidate_sha catalog_digest contradiction
          decision_replay_count duplicate_effects effect_count
          effect_replay_count elapsed_seconds generated_at lane manifest_digest
          modules qualification_id receipt_ids run_id scenario_manifest_digest
          source_digest status supersedes unsettled_effects
        ].freeze
        SUMMARY_KEYS = %w[
          blockers change_windows configuration_digest decision_classes
          decision_count decision_identities elapsed_seconds repository_shas
        ].freeze
        CONTRADICTION_KEYS = %w[kind observed_at receipt_id].freeze

        class << self
          def build(lane:, verified_receipts:, effect_index:, generated_at:,
                    supersedes: nil, contradiction: nil)
            lane = enum(lane, LANES)
            receipts = Array(verified_receipts)
            malformed! if receipts.empty? || receipts.size > MAX_RECEIPTS
            receipts.each do |value|
              malformed! unless value.is_a?(
                PatrolEvidenceVerifier::VerifiedReceipt
              )
            end
            all_evidence = receipts.map(&:receipt)
            unique = receipts.uniq { |value| value.receipt.receipt_id }
            evidence = unique.map(&:receipt)
            enforce_common_bindings!(evidence)
            effect_index = verified_effect_index(effect_index, all_evidence)
            modules = PatrolEvidence::MODULES.to_h do |module_name|
              [ module_name, module_summary(evidence, module_name) ]
            end.freeze
            blockers = modules.flat_map do |module_name, summary|
              summary.fetch("blockers").map do |reason|
                "#{module_name}:#{reason}"
              end
            end
            blockers << "duplicate_effects" unless
              effect_index.duplicate_effects.empty?
            blockers << "unsettled_effects" unless
              effect_index.unsettled_effects.empty?
            if evidence.flat_map(&:effects).any? do |effect|
                 effect.intent.authority != "legacy" &&
                   PatrolEffectIndex::TERMINAL_EFFECT_STATUSES.include?(
                     effect.status
                   )
               end
              blockers << "module_shadow_effect"
            end
            contradiction = contradiction_value(contradiction)
            supersedes = optional_qualification_id(supersedes)
            if contradiction
              malformed! unless supersedes
              malformed! unless evidence.any? do |receipt|
                receipt.receipt_id == contradiction.fetch("receipt_id")
              end
              blockers << "contradictory_telemetry"
            elsif supersedes
              malformed!
            end
            blockers = blockers.uniq.sort.freeze
            status = if contradiction
              "invalidated"
            elsif blockers.empty?
              "qualified"
            else
              "evidence_required"
            end
            occurred = evidence.map { |receipt| Time.iso8601(receipt.capture.occurred_at) }
            attributes = {
              lane: lane,
              run_id: evidence.first.run_id,
              candidate_sha: evidence.first.candidate_sha,
              catalog_digest: evidence.first.catalog_digest,
              source_digest: evidence.first.source_digest,
              manifest_digest: evidence.first.manifest_digest,
              scenario_manifest_digest: evidence.first.scenario_manifest_digest,
              status: status.freeze,
              receipt_ids: evidence.map(&:receipt_id).sort.freeze,
              decision_replay_count: receipts.size - evidence.size,
              modules: modules,
              effect_count: effect_index.effect_count,
              effect_replay_count: effect_index.replay_count,
              duplicate_effects: effect_index.duplicate_effects,
              unsettled_effects: effect_index.unsettled_effects,
              elapsed_seconds: (occurred.max - occurred.min).to_i,
              blockers: blockers,
              supersedes: supersedes,
              contradiction: contradiction,
              generated_at: timestamp(generated_at)
            }
            validate_semantics!(attributes)
            create(attributes)
          rescue ArgumentError, KeyError, NoMethodError, TypeError
            malformed!
          end

          def from_h(value)
            value = PatrolEvidence.immutable_json(
              value, label: "patrol qualification"
            )
            PatrolEvidence.exact_keys!(
              value, KEYS, label: "patrol qualification"
            )
            attributes = {
              lane: enum(value["lane"], LANES),
              run_id: nonempty(value["run_id"]),
              candidate_sha: sha(value["candidate_sha"]),
              catalog_digest: digest(value["catalog_digest"]),
              source_digest: digest(value["source_digest"]),
              manifest_digest: digest(value["manifest_digest"]),
              scenario_manifest_digest: digest(
                value["scenario_manifest_digest"]
              ),
              status: enum(value["status"], STATUSES),
              receipt_ids: id_set(value["receipt_ids"], "evidence"),
              decision_replay_count:
                nonnegative_integer(value["decision_replay_count"]),
              modules: modules_value(value["modules"]),
              effect_count: nonnegative_integer(value["effect_count"]),
              effect_replay_count:
                nonnegative_integer(value["effect_replay_count"]),
              duplicate_effects: string_set(value["duplicate_effects"]),
              unsettled_effects: id_set(
                value["unsettled_effects"], "receipt"
              ),
              elapsed_seconds: nonnegative_integer(value["elapsed_seconds"]),
              blockers: string_set(value["blockers"]),
              supersedes: optional_qualification_id(value["supersedes"]),
              contradiction: contradiction_value(value["contradiction"]),
              generated_at: timestamp(value["generated_at"])
            }
            validate_semantics!(attributes)
            qualification = create(attributes)
            unless qualification.qualification_id == value["qualification_id"] &&
                   PatrolEvidence.canonical(qualification.to_h) ==
                     PatrolEvidence.canonical(value)
              raise Hive::ConfigError,
                    "patrol qualification identity does not match its contents"
            end
            qualification
          rescue ArgumentError, KeyError, NoMethodError, TypeError
            malformed!
          end

          private

          def create(attributes)
            identity = payload(attributes)
            new(
              qualification_id: PatrolEvidence.digest(
                "qualification", identity
              ),
              **attributes
            )
          end

          def payload(attributes, qualification_id: nil)
            {
              "qualification_id" => qualification_id,
              "lane" => attributes.fetch(:lane),
              "run_id" => attributes.fetch(:run_id),
              "candidate_sha" => attributes.fetch(:candidate_sha),
              "catalog_digest" => attributes.fetch(:catalog_digest),
              "source_digest" => attributes.fetch(:source_digest),
              "manifest_digest" => attributes.fetch(:manifest_digest),
              "scenario_manifest_digest" =>
                attributes.fetch(:scenario_manifest_digest),
              "status" => attributes.fetch(:status),
              "receipt_ids" => attributes.fetch(:receipt_ids),
              "decision_replay_count" =>
                attributes.fetch(:decision_replay_count),
              "modules" => attributes.fetch(:modules),
              "effect_count" => attributes.fetch(:effect_count),
              "effect_replay_count" =>
                attributes.fetch(:effect_replay_count),
              "duplicate_effects" => attributes.fetch(:duplicate_effects),
              "unsettled_effects" => attributes.fetch(:unsettled_effects),
              "elapsed_seconds" => attributes.fetch(:elapsed_seconds),
              "blockers" => attributes.fetch(:blockers),
              "supersedes" => attributes.fetch(:supersedes),
              "contradiction" => attributes.fetch(:contradiction),
              "generated_at" => attributes.fetch(:generated_at)
            }.tap do |result|
              result.delete("qualification_id") unless qualification_id
            end
          end

          def enforce_common_bindings!(receipts)
            keys = %i[
              run_id candidate_sha catalog_digest source_digest
              manifest_digest scenario_manifest_digest reviewer
            ]
            keys.each do |key|
              malformed! unless receipts.map { |value| value.public_send(key) }.uniq.one?
            end
            malformed! unless receipts.map do |receipt|
              receipt.repository.fetch("id")
            end.uniq.one?
            malformed! unless receipts.map do |receipt|
              PatrolEvidence.canonical(receipt.capture.project)
            end.uniq.one?
          end

          def verified_effect_index(index, evidence)
            malformed! unless index.is_a?(PatrolEffectIndex)
            rebuilt = PatrolEffectIndex.build(
              receipts: evidence.flat_map(&:effects)
            )
            malformed! unless rebuilt.to_h == index.to_h
            index
          end

          def module_summary(evidence, module_name)
            records = evidence.select do |receipt|
              receipt.capture.module_name == module_name
            end
            enforce_capture_bindings!(records)
            comparable = records.group_by do |receipt|
              comparable_identity(receipt)
            end
            malformed! unless comparable.values.all? do |group|
              group.map(&:decision_class).uniq.one? &&
                group.map do |receipt|
                  PatrolEvidence.canonical(receipt.module_projection.to_h)
                end.uniq.one?
            end
            decision_identities = comparable.keys.map do |identity|
              PatrolEvidence.digest("decision", identity)
            end.sort.freeze
            malformed! unless decision_identities.uniq == decision_identities
            representatives = comparable.values.map(&:first)
            classes = representatives.map(&:decision_class).uniq.sort.freeze
            repositories = representatives.map do |receipt|
              receipt.repository.fetch("sha")
            end.uniq.sort.freeze
            change_windows = representatives.map do |receipt|
              receipt.repository.fetch("change_window")
            end.uniq.sort.freeze
            configurations = records.map(&:configuration_digest).uniq
            occurred = records.map do |receipt|
              Time.iso8601(receipt.capture.occurred_at)
            end
            blockers = []
            blockers << "decision_count_below_#{MIN_DECISIONS}" if
              decision_identities.size < MIN_DECISIONS
            blockers << "decision_class_diversity_below_#{MIN_DECISION_CLASSES}" if
              classes.size < MIN_DECISION_CLASSES
            blockers << "repository_diversity_below_#{MIN_REPOSITORIES}" if
              repositories.size < MIN_REPOSITORIES
            blockers << "change_window_diversity_below_#{MIN_CHANGE_WINDOWS}" if
              change_windows.size < MIN_CHANGE_WINDOWS
            blockers << "configuration_changed" unless configurations.one?
            {
              "decision_count" => decision_identities.size,
              "decision_identities" => decision_identities,
              "decision_classes" => classes,
              "repository_shas" => repositories,
              "change_windows" => change_windows,
              "configuration_digest" =>
                configurations.one? ? configurations.first : nil,
              "elapsed_seconds" =>
                occurred.empty? ? 0 : (occurred.max - occurred.min).to_i,
              "blockers" => blockers.sort.freeze
            }.freeze
          end

          def comparable_identity(receipt)
            {
              "trigger_id" => receipt.capture.trigger.fetch("id"),
              "repository_id" => receipt.repository.fetch("id"),
              "repository_sha" => receipt.repository.fetch("sha"),
              "change_window" => receipt.repository.fetch("change_window")
            }.freeze
          end

          def enforce_capture_bindings!(records)
            %i[capture_id occurrence_id].each do |identifier|
              records.group_by do |receipt|
                receipt.capture.public_send(identifier)
              end.each_value do |group|
                bindings = group.map do |receipt|
                  PatrolEvidence.canonical(
                    "repository" => receipt.repository,
                    "decision_class" => receipt.decision_class,
                    "module_projection" => receipt.module_projection.to_h
                  )
                end
                malformed! unless bindings.uniq.one?
              end
            end
          end

          def modules_value(value)
            PatrolEvidence.exact_keys!(
              value, PatrolEvidence::MODULES,
              label: "patrol qualification"
            )
            PatrolEvidence::MODULES.to_h do |module_name|
              summary = value.fetch(module_name)
              PatrolEvidence.exact_keys!(
                summary, SUMMARY_KEYS, label: "patrol qualification"
              )
              [ module_name, {
                "decision_count" =>
                  nonnegative_integer(summary["decision_count"]),
                "decision_identities" =>
                  id_set(summary["decision_identities"], "decision"),
                "decision_classes" => string_set(summary["decision_classes"]),
                "repository_shas" =>
                  sha_set(summary["repository_shas"]),
                "change_windows" => string_set(summary["change_windows"]),
                "configuration_digest" => summary["configuration_digest"] &&
                  digest(summary["configuration_digest"]),
                "elapsed_seconds" =>
                  nonnegative_integer(summary["elapsed_seconds"]),
                "blockers" => string_set(summary["blockers"])
              }.freeze ]
            end.freeze
          end

          def validate_semantics!(attributes)
            expected_blockers = attributes.fetch(:modules).flat_map do |name, summary|
              count = summary.fetch("decision_count")
              classes = summary.fetch("decision_classes")
              repositories = summary.fetch("repository_shas")
              change_windows = summary.fetch("change_windows")
              malformed! unless summary.fetch("decision_identities").size == count
              malformed! if classes.size > count || repositories.size > count ||
                            change_windows.size > count
              blockers = []
              blockers << "decision_count_below_#{MIN_DECISIONS}" if
                count < MIN_DECISIONS
              blockers << "decision_class_diversity_below_#{MIN_DECISION_CLASSES}" if
                classes.size < MIN_DECISION_CLASSES
              blockers << "repository_diversity_below_#{MIN_REPOSITORIES}" if
                repositories.size < MIN_REPOSITORIES
              blockers << "change_window_diversity_below_#{MIN_CHANGE_WINDOWS}" if
                change_windows.size < MIN_CHANGE_WINDOWS
              blockers << "configuration_changed" if
                summary.fetch("configuration_digest").nil?
              malformed! unless summary.fetch("blockers") == blockers.sort
              blockers.map { |blocker| "#{name}:#{blocker}" }
            end
            decision_count = attributes.fetch(:modules).values.sum do |summary|
              summary.fetch("decision_count")
            end
            malformed! unless attributes.fetch(:receipt_ids).size >= decision_count
            expected_blockers << "duplicate_effects" unless
              attributes.fetch(:duplicate_effects).empty?
            expected_blockers << "unsettled_effects" unless
              attributes.fetch(:unsettled_effects).empty?
            if attributes.fetch(:blockers).include?("module_shadow_effect")
              expected_blockers << "module_shadow_effect"
            end
            contradiction = attributes.fetch(:contradiction)
            if contradiction
              malformed! unless attributes.fetch(:supersedes) &&
                                attributes.fetch(:receipt_ids).include?(
                                  contradiction.fetch("receipt_id")
                                )
              expected_blockers << "contradictory_telemetry"
            else
              malformed! if attributes.fetch(:supersedes)
            end
            expected_blockers = expected_blockers.uniq.sort
            malformed! unless attributes.fetch(:blockers) == expected_blockers
            expected_status = if contradiction
              "invalidated"
            elsif expected_blockers.empty?
              "qualified"
            else
              "evidence_required"
            end
            malformed! unless attributes.fetch(:status) == expected_status
          end

          def contradiction_value(value)
            return nil if value.nil?
            PatrolEvidence.exact_keys!(
              value, CONTRADICTION_KEYS, label: "patrol qualification"
            )
            {
              "kind" => nonempty(value["kind"]),
              "receipt_id" => prefixed_id(value["receipt_id"], "evidence"),
              "observed_at" => timestamp(value["observed_at"])
            }.freeze
          end

          def optional_qualification_id(value)
            value.nil? ? nil : prefixed_id(value, "qualification")
          end

          def enum(value, allowed)
            PatrolEvidence.enum(
              value, allowed, label: "patrol qualification"
            )
          end

          def nonempty(value)
            PatrolEvidence.nonempty(value, label: "patrol qualification")
          end

          def timestamp(value)
            PatrolEvidence.timestamp(value, label: "patrol qualification")
          end

          def nonnegative_integer(value)
            integer = Integer(value)
            malformed! if integer.negative?
            integer
          end

          def string_set(value)
            values = Array(value).map { |item| nonempty(item) }
            malformed! unless values.uniq == values && values.sort == values
            values.freeze
          end

          def sha_set(value)
            values = Array(value).map { |item| sha(item) }
            malformed! unless values.uniq == values && values.sort == values
            values.freeze
          end

          def id_set(value, prefix)
            values = Array(value).map { |item| prefixed_id(item, prefix) }
            malformed! unless values.uniq == values && values.sort == values
            values.freeze
          end

          def prefixed_id(value, prefix)
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

          def sha(value)
            string = value.to_s
            malformed! unless string.match?(/\A[0-9a-f]{40}\z/)
            string.dup.freeze
          end

          def malformed!
            raise Hive::ConfigError, "patrol qualification is malformed"
          end
        end

        def qualified? = status == "qualified"

        def configuration_digests
          modules.transform_values { |value| value["configuration_digest"] }
        end

        def to_h
          self.class.send(
            :payload,
            {
              lane: lane, run_id: run_id, candidate_sha: candidate_sha,
              catalog_digest: catalog_digest, source_digest: source_digest,
              manifest_digest: manifest_digest,
              scenario_manifest_digest: scenario_manifest_digest,
              status: status, receipt_ids: receipt_ids,
              decision_replay_count: decision_replay_count, modules: modules,
              effect_count: effect_count,
              effect_replay_count: effect_replay_count,
              duplicate_effects: duplicate_effects,
              unsettled_effects: unsettled_effects,
              elapsed_seconds: elapsed_seconds, blockers: blockers,
              supersedes: supersedes, contradiction: contradiction,
              generated_at: generated_at
            },
            qualification_id: qualification_id
          ).freeze
        end
      end
    end
  end
end
