require "digest"
require "json"
require "hive/plan_review"

module Hive
  module PlanReview
    module Policy
      Result = Data.define(
        :applicable, :computed_level, :effective_level, :matched_reasons,
        :level_sources, :policy_fingerprint, :classifier_version
      ) do
        def applicable? = applicable

        def to_h
          {
            "applicable" => applicable?,
            "computed_level" => computed_level,
            "effective_level" => effective_level,
            "matched_reasons" => matched_reasons,
            "level_sources" => level_sources,
            "policy_fingerprint" => policy_fingerprint,
            "classifier_version" => classifier_version
          }
        end
      end

      module_function

      def evaluate(workflow_id:, signals:, config:, run_level: nil)
        settings = config.fetch("plan_review", config)
        unless workflow_id.to_s == "coding" && settings.fetch("enabled", true)
          return Result.new(
            applicable: false, computed_level: nil, effective_level: nil,
            matched_reasons: [].freeze, level_sources: {}.freeze,
            policy_fingerprint: nil, classifier_version: classifier_version(settings)
          ).freeze
        end

        computed = computed_level(signals)
        project = Hive::PlanReview.level!(settings.fetch("minimum_level", "skip"),
                                         label: "plan_review.minimum_level")
        workflow = Hive::PlanReview.level!(settings.dig("coding", "minimum_level") || "skip",
                                          label: "plan_review.coding.minimum_level")
        base = Hive::PlanReview.higher_level(computed, project, workflow)
        run = normalize_run_level(run_level, base)
        effective = Hive::PlanReview.higher_level(base, run)
        sources = {
          "computed" => computed,
          "project" => project,
          "workflow" => workflow,
          "run" => run
        }.freeze
        version = classifier_version(settings)
        fingerprint_input = {
          "classifier_version" => version,
          "workflow_id" => workflow_id.to_s,
          "signals" => signals.to_h,
          "policy" => policy_affecting_config(settings),
          "level_sources" => sources
        }

        Result.new(
          applicable: true,
          computed_level: computed.freeze,
          effective_level: effective.freeze,
          matched_reasons: Array(signals.mandatory_reasons).map(&:dup).freeze,
          level_sources: sources,
          policy_fingerprint: Digest::SHA256.hexdigest(canonical_json(fingerprint_input)).freeze,
          classifier_version: version
        ).freeze
      end

      def computed_level(signals)
        return "mandatory" unless Array(signals.mandatory_reasons).empty?
        return "skip" if signals.skip_eligible?

        "standard"
      end

      def normalize_run_level(run_level, base)
        return nil if run_level.nil? || run_level.to_s.empty?

        normalized = Hive::PlanReview.level!(run_level, label: "run review level")
        if Hive::PlanReview::LEVEL_RANK.fetch(normalized) < Hive::PlanReview::LEVEL_RANK.fetch(base)
          raise Hive::ConfigError,
                "run review level cannot lower #{base} to #{normalized}; run overrides are raise-only"
        end
        normalized
      end

      def classifier_version(settings)
        Integer(settings.fetch("classifier_version", Hive::PlanReview::CLASSIFIER_VERSION))
      rescue ArgumentError, TypeError
        raise Hive::ConfigError, "plan_review.classifier_version must be an Integer"
      end

      def policy_affecting_config(settings)
        %w[classifier_version minimum_level coding skip protected_paths attempts coverage].to_h do |key|
          [ key, settings[key] ]
        end
      end

      def canonical_json(value)
        JSON.generate(canonicalize(value))
      end

      def canonicalize(value)
        case value
        when Hash
          value.keys.map(&:to_s).sort.to_h do |key|
            original = value.key?(key) ? key : value.keys.find { |candidate| candidate.to_s == key }
            [ key, canonicalize(value.fetch(original)) ]
          end
        when Array
          value.map { |entry| canonicalize(entry) }
        when Symbol
          value.to_s
        else
          value
        end
      end
    end
  end
end
