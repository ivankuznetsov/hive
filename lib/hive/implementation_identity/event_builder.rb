require "hive/implementation_identity"

module Hive
  module ImplementationIdentity
    EventBuilder = Data.define(:task, :attempt_store) do
      def build(context, event_type:, reason:,
                provenance: { "source" => "generation_resolver" }, payload: {})
        attempt = attempt_store.fetch(context.attempt_id)
        raise ResolutionError, "durable attempt #{context.attempt_id.inspect} is unavailable" unless attempt

        task_id = task.respond_to?(:id) ? task.id&.to_s : nil

        {
          event_type: event_type,
          task: { "id" => task_id, "slug" => task.slug.to_s },
          workflow: "coding", stage: attempt["intended_stage"],
          attempt_id: context.attempt_id,
          task_generation: context.task_generation,
          ownership_generation: context.ownership_generation,
          commit_generation: 0, reason: reason,
          evidence: [ { "type" => "attempt_lease", "attempt_id" => context.attempt_id } ],
          provenance: provenance, payload: payload
        }
      end
    end
  end
end
