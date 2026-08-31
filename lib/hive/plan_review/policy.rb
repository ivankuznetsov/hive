require "hive/canonical_json"
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
          "signals" => signals.to_h.reject { |key, _value| key.to_s == "plan_path" },
          "policy" => policy_affecting_config(
            settings,
            model_routing: review_model_routing(config)
          ),
          "level_sources" => sources
        }

        Result.new(
          applicable: true,
          computed_level: computed.freeze,
          effective_level: effective.freeze,
          matched_reasons: Array(signals.mandatory_reasons).map(&:dup).freeze,
          level_sources: sources,
          policy_fingerprint: Hive::CanonicalJSON.digest(fingerprint_input).freeze,
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

      # `routes` belongs here: a review is a verdict from particular reviewers,
      # so changing who reviews makes the old verdict stale in exactly the way
      # this fingerprint exists to express.
      #
      # Leaving it out had a sharp edge. A review blocked because no reviewer
      # could be launched — `unsupported`, a statement about our tooling and
      # not about the plan — was keyed on inputs that excluded the reviewer.
      # Installing the skill, correcting the route or shipping the gem could
      # not invalidate it, so the stale block replayed forever while telling
      # the operator to "restore required reviewer capability".
      def policy_affecting_config(settings, model_routing: {})
        configured = %w[
          classifier_version minimum_level coding skip protected_paths
          coverage adapter reviewers routes
        ].to_h do |key|
          [ key, settings[key] ]
        end
        # Planner-revision fallback is an operational recovery route, not a
        # reviewer or verdict change. Keeping it outside the fingerprint lets
        # an operator recover a provider-limited revision without discarding
        # the findings and decisions already bound to this review lineage.
        routes = configured["routes"]
        if routes.is_a?(Hash)
          configured["routes"] = routes.reject do |key, _value|
            key.to_s == "planner_revision_fallback"
          end
        end
        return configured if model_routing.empty?

        configured.merge("model_routing" => model_routing)
      end

      def configuration_fingerprint(config)
        settings = config.fetch("plan_review", config)
        Hive::CanonicalJSON.digest(policy_affecting_config(
          settings,
          model_routing: review_model_routing(config)
        ))
      end

      REVIEW_MODEL_ROUTING_KEYS = %w[
        plan_review plan_review_adversarial plan_review_verification
      ].freeze

      def review_model_routing(config)
        return {} unless config.key?("plan_review") && config["models"].is_a?(Hash)

        REVIEW_MODEL_ROUTING_KEYS.filter_map do |key|
          [ key, config["models"][key] ] if config["models"].key?(key)
        end.to_h
      end
    end
  end
end
