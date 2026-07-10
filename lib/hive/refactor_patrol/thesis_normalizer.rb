require "json_schemer"
require "pathname"
require "hive"
require "hive/refactor_patrol/fingerprint"
require "hive/refactor_patrol/thesis"

module Hive
  module RefactorPatrol
    # Turns one raw agent-emitted thesis hash into a schema-valid Thesis,
    # enforcing the evidence-admissibility and behavior-preservation policy.
    # Pure transformation — no I/O and no agent coupling — so the fastest-
    # evolving part of refactor-patrol (what agent output do we accept, and
    # how do we repair honest drift?) lives and is tested in one place.
    class ThesisNormalizer
      VALID_CONFIDENCE = %w[high medium low].freeze
      MEASURABLE_SIGNALS = %w[
        churn
        fan_in
        complexity
        coupling
        repeated_dependency
        bug_density
        coverage_gap
      ].freeze

      # Returned instead of a Thesis when the normalized hash still fails the
      # thesis schema; carries the validation messages for error recording.
      Invalid = Struct.new(:errors, keyword_init: true)

      def initialize(project_root:, commands:)
        @project_root = project_root
        @commands = commands
        @schemer = JSONSchemer.schema(Pathname.new(Hive::Schemas.schema_path("hive-refactor-patrol-thesis")))
      end

      def call(feature:, leverage:, raw:, index:)
        return nil unless raw.is_a?(Hash)

        hash = defaulted_hash(feature, leverage, raw, index)
        enforce_behavior_guidance!(feature, hash)
        enforce_admissibility!(hash)
        thesis = Thesis.from_h(hash)
        thesis.fingerprint = Fingerprint.compute(thesis, project_root: @project_root)
        hash["fingerprint"] = thesis.fingerprint
        return Invalid.new(errors: schema_errors(hash)) unless @schemer.valid?(hash)

        thesis
      end

      private

      def defaulted_hash(feature, leverage, raw, idx)
        boundary = {
          "owned_files" => Array(feature.owned_files),
          "entrypoints" => Array(feature.entrypoints)
        }
        risk = raw["risk"].is_a?(Hash) ? raw["risk"] : {}
        required_validation = raw["required_validation"].is_a?(Hash) ? raw["required_validation"] : {}
        raw_feature = raw["feature"].is_a?(Hash) ? raw["feature"]["id"] : raw["feature"]

        {
          "id" => raw["id"].to_s.empty? ? "#{feature.id}-refactor-#{idx + 1}" : raw["id"].to_s,
          "feature_id" => feature.id.to_s,
          "feature" => raw_feature.to_s.empty? ? feature.id.to_s : raw_feature.to_s,
          "problem" => raw["problem"].to_s,
          "cost" => raw["cost"].to_s,
          "evidence" => normalize_evidence(feature, leverage, Array(raw["evidence"])),
          "proposed_refactor" => raw["proposed_refactor"].to_s.empty? ? raw["refactor"].to_s : raw["proposed_refactor"].to_s,
          "feature_boundary" => boundary.merge(raw["feature_boundary"].is_a?(Hash) ? raw["feature_boundary"] : {}),
          # R5: rank by the deterministic measured-signal blend. The agent's
          # own expected_leverage.score/breakdown is advisory only and is
          # discarded here so it cannot override the computed ranking.
          "expected_leverage" => {
            "score" => (leverage["score"] || 0).to_f,
            "breakdown" => leverage["breakdown"].is_a?(Hash) ? leverage["breakdown"] : {}
          },
          "confidence" => VALID_CONFIDENCE.include?(raw["confidence"].to_s) ? raw["confidence"].to_s : "low",
          "risk" => default_risk(risk),
          "required_validation" => {
            "commands" => Array(required_validation["commands"]),
            "characterization_first" => required_validation["characterization_first"] == true,
            "notes" => (required_validation["notes"] || required_validation["characterization_notes"]).to_s
          },
          "admissible" => raw.key?("admissible") ? raw["admissible"] == true : true,
          "admissibility_reason" => raw["admissibility_reason"].to_s,
          "follow_up_approval_state" => raw["follow_up_approval_state"].to_s.empty? ? "pending" : raw["follow_up_approval_state"].to_s,
          "fingerprint" => raw["fingerprint"].to_s
        }
      end

      # Dogfooding showed agents drift from the evidence contract in
      # predictable, recoverable ways: a plural "files" array instead of
      # "file", a named signal without the measured "value". Repair only what
      # stays honest — paths the agent itself named and values we measured —
      # so admissibility judges the substance of the evidence, not its spelling.
      def normalize_evidence(feature, leverage, items)
        items.flat_map do |item|
          next [ item ] unless item.is_a?(Hash)

          expand_evidence_files(feature, item).map { |entry| backfill_signal_value(leverage, entry) }
        end
      end

      def expand_evidence_files(feature, item)
        return [ item ] unless item["file"].to_s.strip.empty?

        files = Array(item["files"] || item["paths"] || item["path"]).map(&:to_s).reject { |f| f.strip.empty? }
        files = anchored_owned_files(feature, item) if files.empty?
        return [ item ] if files.empty?

        rest = item.reject { |key, _| %w[file files paths path].include?(key) }
        files.map { |file| rest.merge("file" => file) }
      end

      # Anchor file-less evidence to owned files only when the evidence text
      # literally names them — never invent an anchor the agent didn't cite.
      def anchored_owned_files(feature, item)
        text = "#{item["snippet"]} #{item["claim"]}"
        (Array(feature.owned_files) + Array(feature.entrypoints)).uniq.select { |path| text.include?(path) }
      end

      def backfill_signal_value(leverage, item)
        signal = item["signal"].to_s
        return item if item.key?("value") || !MEASURABLE_SIGNALS.include?(signal)

        measured = leverage.is_a?(Hash) ? leverage.dig("signals", signal) : nil
        measured.nil? ? item : item.merge("value" => measured)
      end

      def default_risk(risk)
        caps = risk["caps"].is_a?(Hash) ? risk["caps"] : {}
        {
          "caps" => {
            "est_files" => caps["est_files"].to_i,
            "est_diff_lines" => caps["est_diff_lines"].to_i,
            "single_feature" => caps.key?("single_feature") ? caps["single_feature"] == true : true
          },
          "public_api_impact" => risk["public_api_impact"] == true,
          "public_api_details" => Array(risk["public_api_details"]),
          "cross_feature_impact" => risk["cross_feature_impact"] == true,
          "cross_feature_details" => Array(risk["cross_feature_details"]),
          "flags" => Array(risk["flags"])
        }
      end

      def enforce_behavior_guidance!(feature, hash)
        return enforce_documentation_guidance!(hash) if feature.documentation?

        validation = hash.fetch("required_validation")
        known_commands = @commands.keys
        validation["commands"] = Array(validation["commands"]).map(&:to_s).select { |key| known_commands.include?(key) }
        has_tests = Array(feature.tests).any?

        # R8/A3: every admissible thesis must name validation commands OR opt
        # into characterization-first guidance. When the agent supplies
        # neither, inject the configured test command for test-rich slices and
        # fall back to characterization-first when no command is available.
        if validation["commands"].empty? && !validation["characterization_first"]
          if has_tests && known_commands.include?("test")
            validation["commands"] = [ "test" ]
          else
            validation["characterization_first"] = true
            validation["notes"] = if has_tests
              "Name explicit validation commands or characterize behavior before refactoring."
            else
              "Add characterization tests before refactoring this test-poor slice."
            end
          end
        end

        hash["confidence"] = "medium" if !has_tests && validation["characterization_first"] && hash["confidence"] == "high"
      end

      def enforce_documentation_guidance!(hash)
        validation = hash.fetch("required_validation")
        docs_command = @commands["docs"]
        if docs_command
          validation["commands"] = [ "docs" ]
          validation["characterization_first"] = false
          validation["notes"] = "Run the configured documentation validation before publishing a fix."
        else
          validation["commands"] = []
          validation["characterization_first"] = false
          validation["notes"] = "No documentation validation command is configured; this thesis is report-only."
          hash.fetch("risk").fetch("flags") << "missing_docs_validation"
          hash.fetch("risk")["flags"].uniq!
        end
      end

      def enforce_admissibility!(hash)
        evidence = Array(hash["evidence"])
        has_file = evidence.any? { |item| item.is_a?(Hash) && !item["file"].to_s.strip.empty? }
        has_signal = evidence.any? do |item|
          item.is_a?(Hash) && MEASURABLE_SIGNALS.include?(item["signal"].to_s) && item.key?("value")
        end
        if has_file && has_signal
          hash["admissible"] = true
          hash["admissibility_reason"] = "evidence cites concrete paths and measurable signals"
          return
        end

        hash["admissible"] = false
        reasons = []
        reasons << "missing concrete file path" unless has_file
        reasons << "missing measurable signal" unless has_signal
        hash["admissibility_reason"] = reasons.join("; ")
        hash["risk"]["flags"] |= [ "inadmissible" ]

        # R7/R10/DoD flag-not-drop: a truly evidence-less thesis would fail the
        # schema's evidence.minItems and be dropped as schema_invalid (pinning
        # last_scanned_sha and forcing perpetual re-scan). Seed a synthetic
        # marker so it survives to the report as a flagged inadmissible record.
        if evidence.empty?
          hash["evidence"] = [ { "snippet" => "no evidence supplied; retained as inadmissible" } ]
        end
      end

      def schema_errors(hash)
        @schemer.validate(hash).map { |error| error.fetch("error", error.inspect) }
      end
    end
  end
end
