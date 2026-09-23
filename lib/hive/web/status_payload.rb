require "hive/plan_review/decision_service"

module Hive
  module Web
    # Web keeps current review state and action identity, not reviewer history.
    # Copy only the affected containers so native status remains unchanged.
    module StatusPayload
      def self.call(payload)
        compact = payload
        if payload["projects"].is_a?(Array)
          projects = map_changed(payload["projects"]) { |entry| project(entry) }
          compact = compact.merge("projects" => projects) unless projects.equal?(payload["projects"])
        end
        if payload["project_archives"].is_a?(Hash)
          archives = payload["project_archives"]
          archives.each do |name, history|
            summary = project(history)
            next if summary.equal?(history)

            if compact["project_archives"].equal?(archives)
              compact = compact.merge("project_archives" => archives.dup)
            end
            compact["project_archives"][name] = summary
          end
        end
        compact
      end

      def self.project(attributes)
        return attributes unless attributes["tasks"].is_a?(Array)

        tasks = map_changed(attributes["tasks"]) { |entry| task(entry) }
        tasks.equal?(attributes["tasks"]) ? attributes : attributes.merge("tasks" => tasks)
      end

      def self.task(attributes)
        review = attributes["plan_review"]
        return attributes unless review.is_a?(Hash) && review.key?("routes")

        summary = review.except("routes", "retry_attempt_id")
        if review["state"] == "retry_scheduled"
          latest = Array(review["routes"]).reverse_each.find do |route|
            route.is_a?(Hash) &&
              PlanReview::DecisionService::RECOVERABLE_ROLES.include?(route["role"]) && route["attempt_id"]
          end
          if latest && PlanReview::DecisionService::TRANSIENT_OUTCOMES.include?(latest["outcome"])
            summary["retry_attempt_id"] = latest["attempt_id"]
          end
        end
        attributes.merge("plan_review" => summary)
      end

      def self.map_changed(entries)
        result = entries
        entries.each_with_index do |entry, index|
          value = yield entry
          next if value.equal?(entry)

          result = entries.dup if result.equal?(entries)
          result[index] = value
        end
        result
      end
      private_class_method :map_changed
    end
  end
end
