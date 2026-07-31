require "hive/modules/migration/patrol_evidence_receipt"
require "hive/modules/migration/qualification_run_descriptor"

module Hive
  module Modules
    module Migration
      # Combines one explicitly selected immutable qualification run with
      # current project and module-selection state. The receipt is evidence,
      # never lookup authority: callers supply run and lane independently.
      class LiveBindingsResolver
        RUN_AUTHORITY_KEYS = %w[
          artifact_digests artifact_refs candidate control
          decision_expectations expected_legacy_effect_keys lane lane_policy
          module_selections project required_faults required_matrix run_id
          scenario_manifest_digest
        ].freeze
        BINDING_KEYS =
          (RUN_AUTHORITY_KEYS + [ "configuration_digests" ]).sort.freeze
        STATUSES = %w[
          resolved evidence_required blocked failed
        ].freeze
        STATUS_RANK = {
          "resolved" => 0,
          "evidence_required" => 1,
          "blocked" => 2,
          "failed" => 3
        }.freeze
        SHA = /\A[0-9a-f]{40}\z/
        DIGEST = /\A[0-9a-f]{64}\z/

        Result = Data.define(:status, :bindings, :issues) do
          def resolved? = status == "resolved"
          def blocked? = status == "blocked"
          def failed? = status == "failed"
        end
        ProjectResolution = Data.define(:project, :blockers)

        def initialize(project_provider:, module_selections:,
                       run_authority_provider:)
          unless run_authority_provider.respond_to?(:call)
            raise Hive::ConfigError,
                  "patrol qualification authority provider is required"
          end

          @project_provider = project_provider
          @module_selections = module_selections
          @run_authority_provider = run_authority_provider
        end

        def resolve(run_id:, lane:, receipt:, records:)
          run_id = run_id.to_s
          lane = lane.to_s
          unless QualificationRunDescriptor::RUN_ID.match?(run_id) &&
                 QualificationRunDescriptor::LANES.include?(lane)
            return result(
              "failed", nil,
              [ "live_run_selection_malformed" ]
            )
          end
          provider = provider_outcome(run_id, lane)
          return provider if provider.status != "resolved"
          if receipt.nil? && records.nil?
            return result(
              "evidence_required", nil,
              [ "lane_evidence_missing" ]
            )
          end
          PatrolEvidenceReceipt.from_h(receipt) unless
            receipt.is_a?(PatrolEvidenceReceipt)
          records

          authority = normalize_run_authority(
            provider.bindings,
            selected_run_id: run_id,
            selected_lane: lane
          )
          project_status, live_project, project_issues =
            resolve_live_project
          selection_status, live_selections, selection_issues =
            resolve_live_selections
          issues = project_issues + selection_issues
          control_issues =
            control_qualification_issues(authority)
          issues.concat(control_issues)
          mismatch = false
          if live_project &&
             live_project != authority.fetch("project")
            issues << "project_binding_mismatch"
            mismatch = true
          end
          if live_selections &&
             live_selections != authority.fetch("module_selections")
            issues << "module_selection_binding_mismatch"
            mismatch = true
          end
          statuses = [ project_status, selection_status ]
          statuses << "evidence_required" if mismatch
          statuses << "evidence_required" unless
            control_issues.empty?
          status = highest_status(statuses)
          bindings = authority.merge(
            "configuration_digests" =>
              authority.fetch("module_selections").to_h do |name, selection|
                [
                  name,
                  selection.dig(
                    "active", "configuration_digest"
                  )
                ]
              end
          )
          result(status, bindings, issues)
        rescue Hive::ConfigError, ArgumentError, KeyError,
               NoMethodError, TypeError
          result(
            "failed", nil,
            [ "live_run_authority_malformed" ]
          )
        rescue StandardError
          result(
            "failed", nil,
            [ "live_run_authority_unsafe" ]
          )
        end

        private

        def provider_outcome(run_id, lane)
          source = @run_authority_provider.call(
            run_id: run_id,
            lane: lane
          )
          unless source.is_a?(
            QualificationRunAuthorityProvider::Outcome
          )
            return result(
              "failed", nil,
              [ "live_run_authority_untyped" ]
            )
          end
          status = source.status.to_s
          issues = normalize_issues(source.issues)
          case status
          when "resolved"
            unless source.bindings.is_a?(Hash) && issues.empty?
              return result(
                "failed", nil,
                [ "live_run_authority_malformed" ]
              )
            end
            result("resolved", source.bindings, [])
          when "blocked", "failed"
            unless source.bindings.nil? && !issues.empty?
              return result(
                "failed", nil,
                [ "live_run_authority_malformed" ]
              )
            end
            result(status, nil, issues)
          else
            result(
              "failed", nil,
              [ "live_run_authority_malformed" ]
            )
          end
        rescue StandardError
          result(
            "failed", nil,
            [ "live_run_authority_unsafe" ]
          )
        end

        def normalize_run_authority(source, selected_run_id:,
                                    selected_lane:)
          label = "patrol run authority"
          source = PatrolEvidence.immutable_json(
            source,
            label: label
          )
          PatrolEvidence.exact_keys!(
            source, RUN_AUTHORITY_KEYS, label: label
          )
          unless source["run_id"] == selected_run_id &&
                 source["lane"] == selected_lane
            raise Hive::ConfigError,
                  "patrol run authority selection is malformed"
          end
          validate_candidate!(source.fetch("candidate"), label)
          Hive::Modules::Migration::
            TrustedQualificationControl.normalize(
              source.fetch("control")
            )
          validate_project!(source.fetch("project"), label)
          validate_selections!(
            source.fetch("module_selections"), label
          )
          digest!(
            source.fetch("scenario_manifest_digest"), label
          )
          validate_artifacts!(
            source.fetch("artifact_digests"), label
          )
          validate_decisions!(
            source.fetch("decision_expectations"), label
          )
          validate_string_set!(
            source.fetch("required_matrix"), label
          )
          validate_string_set!(
            source.fetch("required_faults"), label
          )
          validate_effect_keys!(
            source.fetch("expected_legacy_effect_keys"), label
          )
          validate_lane_policy!(
            source.fetch("lane_policy"), selected_lane, label
          )
          validate_artifact_refs!(
            source.fetch("artifact_refs"), selected_lane, label
          )
          source
        end

        def control_qualification_issues(authority)
          control = authority.fetch("control")
          candidate = authority.fetch("candidate")
          issues = []
          issues << "qualification_control_untrusted" unless
            control.fetch("trust_scope") == "trusted_remote"
          issues << "qualification_control_not_independent" if
            control.fetch("commit_sha") ==
              candidate.fetch("commit_sha")
          issues.freeze
        end

        def resolve_live_project
          unless @project_provider.respond_to?(:call)
            return [
              "blocked", nil,
              [ "live_project_binding_unresolved" ]
            ]
          end
          source = @project_provider.call
          issues = []
          if source.is_a?(ProjectResolution)
            issues.concat(normalize_issues(source.blockers))
            source = source.project
          end
          unless source
            issues << "live_project_binding_unresolved" if
              issues.empty?
            return [ "blocked", nil, issues ]
          end
          project = begin
            normalize_project(source)
          rescue Hive::ConfigError
            return [ "blocked", nil, issues ] unless
              issues.empty?
            raise
          end
          status = issues.empty? ?
            "resolved" : "evidence_required"
          [ status, project, issues ]
        rescue Hive::ConfigError, ArgumentError, KeyError,
               NoMethodError, TypeError
          [
            "failed", nil,
            [ "live_project_binding_malformed" ]
          ]
        rescue StandardError
          [
            "failed", nil,
            [ "live_project_binding_unsafe" ]
          ]
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
          unless nonempty?(project_id) && nonempty?(name) &&
                 nonempty?(repository)
            raise Hive::ConfigError,
                  "live project authority is malformed"
          end
          {
            "project_id" => project_id.to_s,
            "name" => name.to_s,
            "repository" => repository.to_s
          }.freeze
        end

        def resolve_live_selections
          unless @module_selections.is_a?(Hash)
            return [
              "blocked", nil,
              [ "live_module_selection_bindings_unresolved" ]
            ]
          end
          issues = []
          selections = PatrolEvidence::MODULES.sort.to_h do |name|
            source = @module_selections[name] ||
              @module_selections[name.to_sym]
            unless source
              issues <<
                "live_module_selection_binding_unresolved:#{name}"
              next [ name, nil ]
            end
            unless source.is_a?(Hash)
              raise Hive::ConfigError,
                    "live module selection is malformed"
            end
            unless source["installed"] == true &&
                   source["enabled"] == true &&
                   source["active"].is_a?(Hash)
              issues <<
                "live_module_selection_binding_unresolved:#{name}"
              next [ name, nil ]
            end
            [
              name,
              normalize_selection(
                {
                  "selection_epoch" => source.fetch("epoch"),
                  "active" => source.fetch("active")
                },
                "live module selection"
              )
            ]
          end
          unless issues.empty?
            return [ "blocked", nil, issues ]
          end
          [ "resolved", selections.freeze, [] ]
        rescue Hive::ConfigError, ArgumentError, KeyError,
               NoMethodError, TypeError
          [
            "failed", nil,
            [ "live_module_selection_bindings_malformed" ]
          ]
        end

        def validate_candidate!(candidate, label)
          PatrolEvidence.exact_keys!(
            candidate,
            QualificationRunDescriptor::CANDIDATE_KEYS,
            label: label
          )
          unless SHA.match?(candidate["commit_sha"].to_s)
            PatrolEvidence.malformed!(label)
          end
          (
            QualificationRunDescriptor::CANDIDATE_KEYS -
              [ "commit_sha" ]
          ).each do |key|
            digest!(candidate[key], label)
          end
        end

        def validate_project!(project, label)
          PatrolEvidence.exact_keys!(
            project,
            QualificationRunDescriptor::PROJECT_KEYS,
            label: label
          )
          project.each_value do |value|
            PatrolEvidence.nonempty(value, label: label)
          end
        end

        def validate_selections!(selections, label)
          PatrolEvidence.exact_keys!(
            selections,
            PatrolEvidence::MODULES,
            label: label
          )
          selections.each_value do |selection|
            normalize_selection(selection, label)
          end
        end

        def normalize_selection(selection, label)
          PatrolEvidence.exact_keys!(
            selection,
            PatrolEvidenceReceipt::MODULE_SELECTION_KEYS,
            label: label
          )
          epoch = Integer(selection["selection_epoch"])
          PatrolEvidence.malformed!(label) unless epoch.positive?
          active = selection.fetch("active")
          PatrolEvidence.exact_keys!(
            active,
            PatrolEvidenceReceipt::ACTIVE_SELECTION_KEYS,
            label: label
          )
          PatrolEvidence.nonempty(
            active["version"], label: label
          )
          %w[catalog_commit source_commit].each do |key|
            PatrolEvidence.malformed!(label) unless
              SHA.match?(active[key].to_s)
          end
          %w[manifest_digest configuration_digest].each do |key|
            digest!(active[key], label)
          end
          {
            "selection_epoch" => epoch,
            "active" => active
          }.freeze
        rescue ArgumentError, KeyError, TypeError
          PatrolEvidence.malformed!(label)
        end

        def validate_artifacts!(artifacts, label)
          unless artifacts.is_a?(Hash) && !artifacts.empty?
            PatrolEvidence.malformed!(label)
          end
          artifacts.each do |name, value|
            unless name.to_s.match?(
              /\A[a-z0-9][a-z0-9_.-]*\z/
            )
              PatrolEvidence.malformed!(label)
            end
            digest!(value, label)
          end
        end

        def validate_decisions!(expectations, label)
          unless expectations.is_a?(Array) &&
                 !expectations.empty?
            PatrolEvidence.malformed!(label)
          end
          keys =
            PatrolEvidenceReceipt::DECISION_KEYS -
              [ "record_digest" ]
          expectations.each do |row|
            PatrolEvidence.exact_keys!(
              row, keys, label: label
            )
            digest!(row["decision_id"], label)
            PatrolEvidence.enum(
              row["module"],
              PatrolEvidence::MODULES,
              label: label
            )
            PatrolEvidence.nonempty(
              row["decision_class"], label: label
            )
            PatrolEvidence.nonempty(
              row["repository"], label: label
            )
            unless SHA.match?(row["repository_sha"].to_s)
              PatrolEvidence.malformed!(label)
            end
            digest!(row["trigger_digest"], label)
            PatrolEvidence.enum(
              row["control"],
              PatrolEvidenceReceipt::CONTROLS,
              label: label
            )
          end
          unless expectations ==
                   expectations.sort_by do |row|
                     row.fetch("decision_id")
                   end &&
                 expectations.map do |row|
                   row.fetch("decision_id")
                 end.uniq.length == expectations.length
            PatrolEvidence.malformed!(label)
          end
        end

        def validate_string_set!(values, label)
          unless values.is_a?(Array) && !values.empty? &&
                 values == values.sort &&
                 values.uniq.length == values.length
            PatrolEvidence.malformed!(label)
          end
          values.each do |value|
            PatrolEvidence.nonempty(value, label: label)
          end
        end

        def validate_effect_keys!(values, label)
          validate_string_set!(values, label)
          values.each do |value|
            PatrolEvidence.hex_id(
              value, "effect", label: label
            )
          end
        end

        def validate_lane_policy!(policy, lane, label)
          PatrolEvidence.exact_keys!(
            policy,
            QualificationRunDescriptor::LANE_KEYS,
            label: label
          )
          expected_kind = lane == "deterministic" ?
            "source_archive" : "installed_target"
          unless policy["kind"] == expected_kind &&
                 SHA.match?(policy["repository_sha"].to_s) &&
                 policy["timeout_seconds"].is_a?(Integer) &&
                 policy["timeout_seconds"].between?(1, 3_600) &&
                 safe_relative?(policy["executable"])
            PatrolEvidence.malformed!(label)
          end
          credentials = policy["credential_bindings"]
          if lane == "deterministic"
            unless policy["network"] == false &&
                   policy["provider"] == "fixture" &&
                   credentials == [] &&
                   policy["target_ref"].to_s.start_with?(
                     "inputs/candidate/"
                   ) &&
                   policy["target_ref"].to_s.end_with?(
                     ".tar.gz"
                   ) &&
                   safe_relative?(policy["target_ref"])
              PatrolEvidence.malformed!(label)
            end
          else
            unless policy["network"] == false &&
                   policy["provider"] == "openrouter" &&
                   policy["target_ref"] ==
                     "inputs/installed-target/target.json" &&
                   credentials.is_a?(Array) &&
                   !credentials.empty? &&
                   credentials == credentials.sort &&
                   credentials.uniq.length ==
                     credentials.length &&
                   credentials.all? do |name|
                     name.to_s.match?(
                       /\A[A-Z][A-Z0-9_]{0,127}\z/
                     )
                   end
              PatrolEvidence.malformed!(label)
            end
          end
        end

        def validate_artifact_refs!(refs, lane, label)
          PatrolEvidence.exact_keys!(
            refs,
            QualificationRunDescriptor::ARTIFACT_KEYS,
            label: label
          )
          expected = {
            "result" => "lanes/#{lane}/result.json",
            "bundle" => "lanes/#{lane}/bundle.json",
            "artifacts" => "lanes/#{lane}/artifacts",
            "repro_json" => "lanes/#{lane}/repro.json",
            "repro_script" => "lanes/#{lane}/repro.sh"
          }
          PatrolEvidence.malformed!(label) unless refs == expected
        end

        def digest!(value, label)
          PatrolEvidence.malformed!(label) unless
            DIGEST.match?(value.to_s)
        end

        def nonempty?(value)
          value.is_a?(String) && !value.empty?
        end

        def safe_relative?(value)
          value.is_a?(String) && !value.empty? &&
            !value.start_with?("/") &&
            !value.include?("\\") &&
            value.split("/", -1).none? do |part|
              part.empty? || part == "." || part == ".."
            end
        end

        def normalize_issues(values)
          issues = Array(values).map(&:to_s)
          if issues.any?(&:empty?)
            raise Hive::ConfigError,
                  "patrol qualification issues are malformed"
          end
          issues.uniq.sort.freeze
        end

        def highest_status(statuses)
          Array(statuses).compact.max_by do |status|
            STATUS_RANK.fetch(status)
          end || "resolved"
        end

        def result(status, bindings, issues)
          unless STATUSES.include?(status)
            raise Hive::ConfigError,
                  "patrol live binding status is malformed"
          end
          normalized_bindings = bindings &&
            PatrolEvidence.immutable_json(
              bindings,
              label: "patrol evidence live bindings"
            )
          Result.new(
            status: status,
            bindings: normalized_bindings,
            issues: normalize_issues(issues)
          ).freeze
        end
      end
    end
  end
end
