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

      # `routes` belongs here: an unfinished review is waiting on particular
      # reviewers, so changing who reviews must restart it.
      #
      # Leaving it out had a sharp edge. A review blocked because no reviewer
      # could be launched — `unsupported`, a statement about our tooling and
      # not about the plan — was keyed on inputs that excluded the reviewer.
      # Installing the skill, correcting the route or shipping the gem could
      # not invalidate it, so the stale block replayed forever while telling
      # the operator to "restore required reviewer capability".
      #
      # A resolved review is different: its verdict already exists, and who
      # would review next says nothing about it. `configuration_current?`
      # compares a resolved review with its own reviewer routing put back, so
      # only the verdict-relevant part of this configuration can stale it.
      def policy_affecting_config(settings, model_routing: {})
        configured = %w[
          classifier_version minimum_level coding skip protected_paths
          coverage adapter reviewers routes
        ].to_h do |key|
          [ key, settings[key] ]
        end
        configured = configured.merge(
          "adapter_contract_version" => Hive::PlanReview::ADAPTER_CONTRACT_VERSION
        )
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

      REVIEWER_ROLES = %w[primary adversarial verification].freeze
      # Configured route row field => the route receipt `requested` field
      # RouteResolver copies it into.
      ROUTE_RECEIPT_FIELDS = {
        "agent" => "provider", "model" => "model", "family" => "family",
        "effort" => "effort", "route" => "route"
      }.freeze

      # Who reviews, as opposed to what a review must establish: the reviewer
      # identities, their routes and the review model routing they resolve
      # through. Policy artifacts record it as `reviewer_routing`.
      def reviewer_routing(config)
        settings = config.fetch("plan_review", config)
        affecting = policy_affecting_config(settings)
        {
          "reviewers" => affecting["reviewers"],
          "routes" => affecting["routes"],
          "model_routing" => review_model_routing(config)
        }
      end

      # `config` with its reviewer routing replaced. For fingerprinting only:
      # nothing may route a reviewer from the result.
      def with_reviewer_routing(config, routing)
        settings = config.fetch("plan_review", config)
        rerouted = settings.merge(
          "reviewers" => routing["reviewers"], "routes" => routing["routes"]
        )
        return rerouted unless config.key?("plan_review")

        models = config["models"].is_a?(Hash) ? config["models"].except(*REVIEW_MODEL_ROUTING_KEYS) : {}
        config.merge(
          "plan_review" => rerouted,
          "models" => models.merge(routing["model_routing"].is_a?(Hash) ? routing["model_routing"] : {})
        )
      end

      # Whether the configuration a review's policy artifact recorded still
      # holds. An unresolved review compares all of it, reviewer routing
      # included: rerouting must restart a review that is still waiting on
      # (or blocked by) a reviewer. A resolved review (skipped, cleared,
      # degraded_cleared) compares only what a review must establish: level
      # and coverage requirements, skip limits, protected paths, classifier
      # version, adapter and its contract. Rerouting reviewers after the
      # verdict (a provider out of quota, then the revert) must not send
      # executing work back to plan.
      def configuration_current?(config, artifact:, record:)
        recorded = artifact["configuration_fingerprint"]
        return true if recorded == configuration_fingerprint(config)
        return false unless record.execution_allowed?

        recorded == configuration_fingerprint(resolved_review_config(config, artifact:, record:))
      end

      # Today's verdict-relevant configuration with the reviewer routing the
      # resolved review actually ran under. Comparing its fingerprint with the
      # recorded one isolates verdict-relevant drift.
      def resolved_review_config(config, artifact:, record:)
        routing = artifact["reviewer_routing"]
        routing = legacy_reviewer_routing(config, record) unless routing.is_a?(Hash)
        with_reviewer_routing(config, routing)
      end

      # Policy artifacts written before `reviewer_routing` was recorded carry
      # only the combined digest. A reviewer's route receipt `requested` is
      # the configured row it ran, so rebuild the routing from the review's
      # own receipts; a role that never ran keeps today's row. The rebuild is
      # trusted only when it reproduces the recorded digest, so a wrong one
      # (a role rerouted without a receipt, a model routing override) leaves
      # the review stale exactly as before.
      def legacy_reviewer_routing(config, record)
        routing = reviewer_routing(config)
        routes = routing["routes"].is_a?(Hash) ? routing["routes"].dup : {}
        REVIEWER_ROLES.each do |role|
          requested = latest_requested_route(record, role)
          next unless requested

          routes[role] = ROUTE_RECEIPT_FIELDS.transform_values { |field| requested[field] }
        end
        routing.merge("routes" => routes)
      end

      def latest_requested_route(record, role)
        Array(record["routes"]).reverse_each do |receipt|
          next unless receipt.is_a?(Hash) && receipt["role"] == role

          requested = receipt["requested"]
          return requested if requested.is_a?(Hash) && !requested.empty?
        end
        nil
      end
      private_class_method :latest_requested_route
    end
  end
end
