require "json"
require "hive"
require "hive/config"
require "hive/plan_review/projection"
require "hive/plan_review/transition_guard"
require "hive/task_resolver"

module Hive
  module Commands
    # Read-only view of the current plan critique. Decisions must quote the
    # live review, generation, policy, and observation identities; operational
    # status can serve a daemon-cached snapshot that lags each decision, so
    # this reads the task's projection directly and takes no lock.
    class PlanReviewShow
      include Hive::Schemas::EnvelopeEmitter

      IDENTITY_KEYS = %w[
        review_id task_generation policy_fingerprint observation_digest
        state outcome execution_allowed required_action
      ].freeze
      FINDING_KEYS = %w[fingerprint classification risk lifecycle title].freeze

      def initialize(target, project: nil, json: false, resolver: nil, freshness: nil)
        @target = target
        @project = project
        @json = json
        # Same check decisions pass: a review of an older plan, generation, or
        # policy cannot accept decisions until a linked review runs.
        @freshness = freshness || lambda do |task, projection|
          Hive::PlanReview::TransitionGuard.freshness(
            task:, projection:, config: Hive::Config.load(task.project_root)
          )
        end
        @resolver = resolver || lambda do
          Hive::TaskResolver.new(@target, project_filter: @project).resolve
        end
      end

      def call
        call_with_envelope { do_call }
      end

      def envelope_schema = "hive-plan-review-show"

      def envelope_error_kind(error)
        case error
        when Hive::AmbiguousSlug then "ambiguous_slug"
        when Hive::InvalidTaskPath then "invalid_task_path"
        when Hive::PlanReview::Error then "plan_review_unavailable"
        else "error"
        end
      end

      private

      def do_call
        task = @resolver.call
        projection = Hive::PlanReview::Projection.load(task_folder: task.folder)
        payload = payload_for(task, projection)
        @json ? puts(JSON.generate(payload)) : print_human(payload)
        payload
      end

      def payload_for(task, projection)
        summary = projection.summary
        open = projection.record["findings"].select { |finding| finding["lifecycle"] == "open" }
        {
          "schema" => envelope_schema,
          "schema_version" => Hive::Schemas::SCHEMA_VERSIONS.fetch(envelope_schema),
          "ok" => true,
          "slug" => task.slug,
          "task_folder" => task.folder,
          **IDENTITY_KEYS.to_h { |key| [ key, summary[key] ] },
          "task_generation" => summary["task_generation"].to_s,
          "freshness" => @freshness.call(task, projection).to_h { |key, value| [ key.to_s, value ] },
          "open_findings" => open.sort_by { |finding| finding["display_order"].to_i }
                                 .map { |finding| FINDING_KEYS.to_h { |key| [ key, finding[key] ] } }
        }
      end

      def print_human(payload)
        puts "plan review #{payload['review_id']} #{payload['state']} for #{payload['slug']}"
        puts "  task_generation: #{payload['task_generation']}"
        puts "  policy_fingerprint: #{payload['policy_fingerprint']}"
        puts "  observation_digest: #{payload['observation_digest']}"
        puts "  required_action: #{payload['required_action']}" if payload["required_action"]
        freshness = payload["freshness"]
        unless freshness["status"] == "current"
          puts "  freshness: #{freshness['status']} (#{freshness['reason']}); decisions need a linked review first"
        end
        payload["open_findings"].each do |finding|
          puts "  - #{finding['fingerprint']} [#{finding['classification']}, #{finding['risk']}] #{finding['title']}"
        end
      end
    end
  end
end
