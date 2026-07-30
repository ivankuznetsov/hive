require "hive/modules/migration/patrol_evidence_receipt"
require "hive/modules/migration/patrol_evidence_verifier"

module Hive
  module Modules
    module Migration
      # Resolves authority that a persisted evidence bundle cannot prove about
      # itself. Project identity and active module selections come from live
      # runtime state. Run evidence authority is loaded through one narrow
      # run/lane lookup; production deliberately fails closed until that source
      # is wired.
      class LiveBindingsResolver
        RUN_AUTHORITY_KEYS = %w[
          artifact_digests candidate decision_expectations
          expected_legacy_effect_keys lane required_matrix run_id
          scenario_manifest_digest
        ].freeze
        SHA = /\A[0-9a-f]{40}\z/
        DIGEST = /\A[0-9a-f]{64}\z/

        Result = Data.define(:bindings, :blockers)
        ProjectResolution = Data.define(:project, :blockers)

        def initialize(project_provider:, module_selections:,
                       run_authority_provider: nil)
          @project_provider = project_provider
          @module_selections = module_selections
          @run_authority_provider = run_authority_provider
        end

        def resolve(receipt:, records:)
          receipt = receipt.is_a?(PatrolEvidenceReceipt) ?
            receipt :
            PatrolEvidenceReceipt.from_h(receipt)
          payload = receipt.to_h
          blockers = []
          project = live_project(blockers)
          selections = live_selections(blockers)
          authority = live_run_authority(
            run_id: payload.fetch("run_id"),
            lane: payload.fetch("lane"),
            blockers: blockers
          )
          bindings = authority.merge(
            "project" => project,
            "module_selections" => selections,
            "configuration_digests" =>
              selections.to_h do |name, selection|
                [
                  name,
                  selection.dig(
                    "active",
                    "configuration_digest"
                  )
                ]
              end
          )
          Result.new(
            bindings: PatrolEvidence.immutable_json(
              bindings,
              label: "patrol evidence live bindings"
            ),
            blockers: blockers.uniq.sort.freeze
          ).freeze
        end

        private

        def live_project(blockers)
          unless @project_provider.respond_to?(:call)
            blockers << "live_project_binding_unresolved"
            return unresolved_project
          end

          source = @project_provider.call
          if source.is_a?(ProjectResolution)
            blockers.concat(Array(source.blockers).map(&:to_s))
            source = source.project
          end
          if source.nil?
            blockers << "live_project_binding_unresolved" if
              blockers.empty?
            return unresolved_project
          end

          normalize_project(source)
        rescue Hive::ConfigError, ArgumentError, KeyError, TypeError
          blockers << "live_project_binding_malformed"
          unresolved_project
        rescue StandardError
          blockers << "live_project_binding_unsafe"
          unresolved_project
        end

        def normalize_project(source)
          unless source.is_a?(Hash)
            raise Hive::ConfigError,
                  "live project authority is malformed"
          end
          project_id = source["project_id"] ||
            source[:project_id]
          name = source["name"] || source[:name]
          repository = if source.key?("repository")
            source["repository"]
          elsif source.key?(:repository)
            source[:repository]
          else
            source["repository_identity"] ||
              source[:repository_identity]
          end
          if project_id.to_s.empty? || name.to_s.empty?
            raise Hive::ConfigError,
                  "live project authority is malformed"
          end
          if !repository.nil? && repository.to_s.empty?
            raise Hive::ConfigError,
                  "live project authority is malformed"
          end

          {
            "project_id" => project_id.to_s,
            "name" => name.to_s,
            "repository" =>
              repository.nil? ? nil : repository.to_s
          }
        end

        def unresolved_project
          {
            "project_id" => "unresolved",
            "name" => "unresolved",
            "repository" => nil
          }
        end

        def live_selections(blockers)
          unless @module_selections.is_a?(Hash)
            blockers << "live_module_selection_bindings_unresolved"
            return unresolved_selections
          end

          PatrolEvidence::MODULES.sort.to_h do |name|
            source = @module_selections[name] ||
              @module_selections[name.to_sym]
            unless source.is_a?(Hash) &&
                   source["installed"] == true &&
                   source["enabled"] == true &&
                   source["active"].is_a?(Hash)
              blockers <<
                "live_module_selection_binding_unresolved:#{name}"
              next [ name, unresolved_selection(name) ]
            end
            [
              name,
              {
                "selection_epoch" => source.fetch("epoch"),
                "active" => source.fetch("active")
              }
            ]
          end
        rescue KeyError, TypeError
          blockers << "live_module_selection_bindings_unresolved"
          unresolved_selections
        end

        def unresolved_selections
          PatrolEvidence::MODULES.sort.to_h do |name|
            [ name, unresolved_selection(name) ]
          end
        end

        def unresolved_selection(name)
          marker = name == "patrol" ? "0" : "1"
          {
            "selection_epoch" => 1,
            "active" => {
              "version" => "0.0.0",
              "catalog_commit" => marker * 40,
              "source_commit" => marker * 40,
              "manifest_digest" => marker * 64,
              "configuration_digest" => marker * 64
            }
          }
        end

        def live_run_authority(run_id:, lane:, blockers:)
          unless @run_authority_provider.respond_to?(:call)
            blockers << "live_run_authority_unresolved"
            return unresolved_run_authority
          end

          source = begin
            @run_authority_provider.call(
              run_id: run_id,
              lane: lane
            )
          rescue StandardError
            blockers << "live_run_authority_unsafe"
            return unresolved_run_authority
          end
          if source.nil?
            blockers << "live_run_authority_unresolved"
            return unresolved_run_authority
          end

          normalize_run_authority(source)
        rescue Hive::ConfigError, ArgumentError, KeyError,
               NoMethodError, TypeError
          blockers << "live_run_authority_malformed"
          unresolved_run_authority
        end

        def normalize_run_authority(source)
          label = "patrol run authority"
          source = PatrolEvidence.immutable_json(
            source,
            label: label
          )
          PatrolEvidence.exact_keys!(
            source,
            RUN_AUTHORITY_KEYS,
            label: label
          )
          PatrolEvidence.nonempty(source["run_id"], label: label)
          PatrolEvidence.enum(
            source["lane"],
            PatrolEvidenceReceipt::LANES,
            label: label
          )
          validate_candidate!(source.fetch("candidate"), source["lane"])
          digest!(
            source.fetch("scenario_manifest_digest"),
            label
          )
          validate_artifacts!(source.fetch("artifact_digests"))
          validate_decision_expectations!(
            source.fetch("decision_expectations")
          )
          validate_required_matrix!(source.fetch("required_matrix"))
          validate_effect_keys!(
            source.fetch("expected_legacy_effect_keys")
          )
          source
        end

        def validate_candidate!(candidate, lane)
          label = "patrol run authority"
          PatrolEvidence.exact_keys!(
            candidate,
            PatrolEvidenceReceipt::CANDIDATE_KEYS,
            label: label
          )
          malformed!(label) unless SHA.match?(candidate["sha"].to_s)
          %w[catalog_digest source_digest manifest_digest].each do |key|
            digest!(candidate[key], label)
          end
          installed = candidate["installed_digest"]
          if lane == "installed"
            digest!(installed, label)
          else
            malformed!(label) unless installed.nil?
          end
        end

        def validate_artifacts!(artifacts)
          label = "patrol run authority"
          malformed!(label) unless
            artifacts.is_a?(Hash) && !artifacts.empty?
          artifacts.each do |name, digest|
            PatrolEvidence.nonempty(name, label: label)
            digest!(digest, label)
          end
        end

        def validate_decision_expectations!(expectations)
          label = "patrol run authority"
          malformed!(label) unless
            expectations.is_a?(Array) && !expectations.empty?
          expected_keys =
            PatrolEvidenceReceipt::DECISION_KEYS -
            [ "record_digest" ]
          expectations.each do |row|
            PatrolEvidence.exact_keys!(
              row,
              expected_keys,
              label: label
            )
            digest!(row["decision_id"], label)
            PatrolEvidence.enum(
              row["module"],
              PatrolEvidence::MODULES,
              label: label
            )
            PatrolEvidence.nonempty(
              row["decision_class"],
              label: label
            )
            PatrolEvidence.nonempty(row["repository"], label: label)
            malformed!(label) unless
              SHA.match?(row["repository_sha"].to_s)
            digest!(row["trigger_digest"], label)
            PatrolEvidence.enum(
              row["control"],
              PatrolEvidenceReceipt::CONTROLS,
              label: label
            )
          end
          malformed!(label) unless
            expectations.map { |row| row["decision_id"] }.uniq.length ==
              expectations.length
        end

        def validate_required_matrix!(matrix)
          label = "patrol run authority"
          malformed!(label) unless
            matrix.is_a?(Array) && !matrix.empty? &&
            matrix.uniq.length == matrix.length
          matrix.each do |entry|
            PatrolEvidence.nonempty(entry, label: label)
          end
        end

        def validate_effect_keys!(keys)
          label = "patrol run authority"
          malformed!(label) unless
            keys.is_a?(Array) && !keys.empty? &&
            keys.uniq.length == keys.length
          keys.each do |key|
            PatrolEvidence.hex_id(key, "effect", label: label)
          end
        end

        def digest!(value, label)
          malformed!(label) unless DIGEST.match?(value.to_s)
        end

        def malformed!(label)
          PatrolEvidence.malformed!(label)
        end

        def unresolved_run_authority
          {
            "run_id" => "unresolved",
            "lane" => "deterministic",
            "candidate" => {
              "sha" => "0" * 40,
              "catalog_digest" => "0" * 64,
              "source_digest" => "0" * 64,
              "manifest_digest" => "0" * 64,
              "installed_digest" => nil
            },
            "scenario_manifest_digest" => "0" * 64,
            "artifact_digests" => {
              "unresolved" => "0" * 64
            },
            "decision_expectations" => [],
            "required_matrix" => [],
            "expected_legacy_effect_keys" => []
          }
        end
      end
    end
  end
end
