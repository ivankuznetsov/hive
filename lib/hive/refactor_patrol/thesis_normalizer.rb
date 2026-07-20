require "json_schemer"
require "pathname"
require "hive"
require "hive/patrol/source_reader"
require "hive/refactor_patrol/caps"
require "hive/refactor_patrol/fingerprint"
require "hive/refactor_patrol/leverage"
require "hive/refactor_patrol/thesis"

module Hive
  module RefactorPatrol
    # Turns one raw agent-emitted thesis hash into a schema-valid Thesis,
    # enforcing the evidence-admissibility and behavior-preservation policy.
    # It has no agent coupling, but it deliberately verifies cited repository
    # bytes: a structurally plausible path/line/snippet is not evidence unless
    # it exists in the pinned analysis checkout.
    class ThesisNormalizer
      VALID_CONFIDENCE = %w[high medium low].freeze
      EVIDENCE_KEYS = %w[file line snippet claim].freeze

      # Returned instead of a Thesis when the normalized hash still fails the
      # thesis schema; carries the validation messages for error recording.
      Invalid = Struct.new(:errors, keyword_init: true)

      def initialize(project_root:, commands:, min_leverage_score: 0.0, source_reader: nil)
        @project_root = File.expand_path(project_root)
        @commands = commands
        @min_leverage_score = min_leverage_score.to_f
        @source_reader = source_reader || Hive::Patrol::SourceReader.new(@project_root)
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
        raw_boundary = raw["feature_boundary"].is_a?(Hash) ? raw["feature_boundary"] : {}
        feature_hotspot = normalize_feature_hotspot(leverage)
        drivers, invalid_drivers = normalize_drivers(raw["expected_leverage"])
        normalized_risk = default_risk(risk)
        normalized_risk["flags"] |= [ "invalid_leverage_driver" ] if invalid_drivers
        normalized_risk["flags"] |= [ "boundary_override_attempt" ] if boundary_override?(boundary, raw_boundary)

        {
          "id" => raw["id"].to_s.empty? ? "#{feature.id}-refactor-#{idx + 1}" : raw["id"].to_s,
          "feature_id" => feature.id.to_s,
          "feature" => raw_feature.to_s.empty? ? feature.id.to_s : raw_feature.to_s,
          "problem" => raw["problem"].to_s,
          "cost" => raw["cost"].to_s,
          "evidence" => normalize_evidence(feature, Array(raw["evidence"])),
          "proposed_refactor" => raw["proposed_refactor"].to_s.empty? ? raw["refactor"].to_s : raw["proposed_refactor"].to_s,
          # Mapper ownership is authoritative. Agent output may describe risk,
          # but it can never broaden or replace the files that the fixer is
          # permitted to touch.
          "feature_boundary" => boundary,
          "feature_hotspot" => feature_hotspot,
          # The model identifies which language-neutral hotspot drivers the
          # proposal relieves and explains the mechanism. Hive ignores any
          # model-authored score/breakdown and derives the ranking contribution
          # from the measured feature hotspot and bounded relief fractions.
          "expected_leverage" => Leverage.score_proposal(feature_hotspot, drivers),
          "confidence" => VALID_CONFIDENCE.include?(raw["confidence"].to_s) ? raw["confidence"].to_s : "low",
          "risk" => normalized_risk,
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

      def normalize_feature_hotspot(leverage)
        source = leverage.is_a?(Hash) ? leverage : {}
        {
          "scope" => "feature",
          "score" => numeric(source["score"]),
          "breakdown" => numeric_signal_hash(source["breakdown"]),
          "signals" => numeric_signal_hash(source["signals"]),
          "normalized" => numeric_signal_hash(source["normalized"]),
          "measurement" => normalize_feature_measurement(source["measurement"])
        }
      end

      def normalize_feature_measurement(value)
        source = value.is_a?(Hash) ? value : {}
        diagnostics = Array(source["diagnostics"]).filter_map do |diagnostic|
          next unless diagnostic.is_a?(Hash)

          kind = diagnostic["kind"].to_s.strip
          error_class = diagnostic["error_class"].to_s.strip
          message = diagnostic["message"].to_s.strip
          next if kind.empty? || error_class.empty? || message.empty?

          {
            "kind" => kind[0, 80],
            "error_class" => error_class[0, 120],
            "message" => message[0, 500]
          }
        end.first(8)
        {
          "status" => source["status"] == "incomplete" ? "incomplete" : "complete",
          "diagnostics" => diagnostics
        }
      end

      def boundary_override?(canonical, candidate)
        return false if candidate.empty?

        normalized = {
          "owned_files" => Array(candidate["owned_files"]),
          "entrypoints" => Array(candidate["entrypoints"])
        }
        normalized != canonical
      end

      def normalize_drivers(expected_leverage)
        source = expected_leverage.is_a?(Hash) ? expected_leverage : {}
        seen = {}
        invalid = false
        drivers = Array(source["drivers"]).filter_map do |driver|
          unless driver.is_a?(Hash)
            invalid = true
            next
          end

          signal = driver["signal"].to_s
          relief = driver["relief"]
          mechanism = driver["mechanism"].to_s.strip
          valid = Leverage::SIGNALS.include?(signal) &&
                  relief.is_a?(Numeric) && relief.to_f.finite? && relief.to_f.between?(0.0, 1.0) &&
                  !mechanism.empty? && !seen[signal]
          unless valid
            invalid = true
            next
          end

          seen[signal] = true
          { "signal" => signal, "relief" => relief.to_f, "mechanism" => mechanism }
        end
        [ drivers, invalid ]
      end

      def numeric_signal_hash(value)
        source = value.is_a?(Hash) ? value : {}
        source.each_with_object({}) do |(signal, amount), result|
          next unless Leverage::SIGNALS.include?(signal.to_s) && amount.is_a?(Numeric)

          result[signal.to_s] = amount.to_f
        end
      end

      def numeric(value)
        value.is_a?(Numeric) ? value.to_f : 0.0
      end

      # Plural path aliases are recoverable, but feature-wide hotspot values are
      # not line evidence. Canonical evidence retains only language-neutral code
      # anchors and claims; legacy signal/value keys are deliberately stripped.
      def normalize_evidence(feature, items)
        items.flat_map do |item|
          next [ { "claim" => "non-object evidence supplied; retained as inadmissible" } ] unless item.is_a?(Hash)

          expand_evidence_files(feature, item).map { |entry| canonical_evidence(entry) }
        end
      end

      def canonical_evidence(item)
        item.each_with_object({}) do |(key, value), result|
          next unless EVIDENCE_KEYS.include?(key)

          case key
          when "line"
            line = integer(value)
            result[key] = line if line&.positive?
          else
            text = value.to_s.strip
            result[key] = text unless text.empty?
          end
        end
      end

      def integer(value)
        return value if value.is_a?(Integer)
        return Integer(value, exception: false) if value.is_a?(String)

        nil
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

      def default_risk(risk)
        caps = risk["caps"].is_a?(Hash) ? risk["caps"] : {}
        {
          "caps" => {
            "single_feature" => caps.key?("single_feature") ? caps["single_feature"] == true : true
          },
          "public_api_impact" => risk["public_api_impact"] == true,
          "public_api_details" => Array(risk["public_api_details"]),
          "cross_feature_impact" => risk["cross_feature_impact"] == true,
          "cross_feature_details" => Array(risk["cross_feature_details"]),
          "flags" => Caps.without_legacy_size_flags(risk["flags"])
        }
      end

      def enforce_behavior_guidance!(feature, hash)
        return enforce_documentation_guidance!(feature, hash) if feature.documentation?

        validation = hash.fetch("required_validation")
        known_commands = @commands.keys
        validation["commands"] = Array(validation["commands"]).map(&:to_s).select { |key| known_commands.include?(key) }
        has_tests = Array(feature.tests).any?

        # Every automatically actionable thesis needs an executable validation
        # command. Characterization-first remains useful report guidance, but
        # it does not pretend an unimplemented future test can validate a fix.
        # When possible, inject the configured test command for test-rich
        # slices; otherwise retain the thesis as explicitly report-only.
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

        if validation["commands"].empty?
          hash.fetch("risk").fetch("flags") << "missing_behavior_validation"
          hash.fetch("risk")["flags"].uniq!
        end

        hash["confidence"] = "medium" if !has_tests && validation["characterization_first"] && hash["confidence"] == "high"
      end

      def enforce_documentation_guidance!(feature, hash)
        validation = hash.fetch("required_validation")
        docs_command = @commands["docs"]
        if docs_command
          validation["commands"] = [ "docs" ]
          validation["characterization_first"] = false
          validation["notes"] = "Run the configured documentation validation before publishing a fix."
        elsif built_in_documentation_validation_available?(feature)
          validation["commands"] = []
          validation["characterization_first"] = false
          validation["notes"] = "Use Hive's built-in documentation safety checks before normal PR review."
        else
          validation["commands"] = []
          validation["characterization_first"] = false
          validation["notes"] = "Configure an executable docs validation command before automatic refactoring."
          hash.fetch("risk").fetch("flags") << "missing_docs_validation"
          hash.fetch("risk")["flags"].uniq!
        end
      end

      def built_in_documentation_validation_available?(feature)
        paths = Array(feature.owned_files) + Array(feature.entrypoints)
        paths.any? && paths.all? { |path| Caps.documentation_path?(path) }
      end

      def enforce_admissibility!(hash)
        measurement_complete = hash.dig("feature_hotspot", "measurement", "status") == "complete"
        unless measurement_complete
          hash.fetch("risk").fetch("flags") << "incomplete_leverage_measurement"
          hash.fetch("risk")["flags"].uniq!
        end
        if hash.dig("expected_leverage", "score").to_f < @min_leverage_score
          hash.fetch("risk").fetch("flags") << "below_min_leverage"
          hash.fetch("risk")["flags"].uniq!
        end
        evidence = Array(hash["evidence"])
        verified = evidence.map { |item| coherent_anchor?(item) }
        has_anchor = verified.any?
        has_unverified_evidence = verified.any?(false)
        if has_unverified_evidence
          hash.fetch("risk").fetch("flags") << "unverified_evidence"
          hash.fetch("risk")["flags"].uniq!
        end
        has_driver = Array(hash.dig("expected_leverage", "drivers")).any?
        invalid_driver = Array(hash.dig("risk", "flags")).include?("invalid_leverage_driver")
        if has_anchor && !has_unverified_evidence && has_driver && !invalid_driver && measurement_complete
          hash["admissible"] = true
          hash["admissibility_reason"] =
            "evidence is verified against repository bytes and proposal names measurable leverage drivers"
          return
        end

        hash["admissible"] = false
        reasons = []
        reasons << "missing coherent anchored claim" unless has_anchor
        reasons << "unverified evidence anchor" if has_unverified_evidence
        reasons << "missing valid proposal leverage driver" unless has_driver
        reasons << "invalid proposal leverage driver" if invalid_driver
        reasons << "incomplete feature leverage measurement" unless measurement_complete
        hash["admissibility_reason"] = reasons.join("; ")
        hash["risk"]["flags"] |= [ "inadmissible" ]

        # R7/R10/DoD flag-not-drop: a truly evidence-less thesis would fail the
        # schema's evidence.minItems and be dropped as schema_invalid (pinning
        # last_scanned_sha and forcing perpetual re-scan). Seed a synthetic
        # marker so it survives to the report as a flagged inadmissible record.
        if evidence.empty?
          hash["evidence"] = [ { "claim" => "no evidence supplied; retained as inadmissible" } ]
        end
      end

      def coherent_anchor?(item)
        return false unless item.is_a?(Hash)

        file = item["file"].to_s.strip
        claim = item["claim"].to_s.strip
        line = item["line"]
        snippet = item["snippet"].to_s.strip
        return false if file.empty? || claim.empty?

        content = verified_evidence_content(file)
        return false unless content

        line_valid = line.nil? || (line.is_a?(Integer) && line.positive? && line <= content.lines.size)
        location_valid = snippet.empty? ? line.is_a?(Integer) && line_valid : line_valid && content.include?(snippet)
        location_valid
      end

      def verified_evidence_content(file)
        return if file.include?("\\")

        relative = Pathname.new(file)
        return if relative.absolute? || relative.cleanpath.to_s != file || file == "."

        return unless @source_reader.regular_file?(file)

        @source_reader.read_utf8(file)
      rescue SystemCallError, ArgumentError
        nil
      end

      def schema_errors(hash)
        @schemer.validate(hash).map { |error| error.fetch("error", error.inspect) }
      end
    end
  end
end
