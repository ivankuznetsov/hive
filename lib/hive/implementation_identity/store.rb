require "hive/attempts/context"
require "hive/attempts/repository"
require "hive/conditions/generation_tracker"
require "hive/implementation_identity/event_builder"
require "hive/implementation_identity/resolver"
require "hive/agent_support"
require "hive/task_journal"
require "hive/task_projection/store"
require "digest"
require "json"

module Hive
  module ImplementationIdentity
    class Store
      def initialize(task:, cfg:, attempt_store: nil, writer: nil, projection_store: nil,
                     resolver: nil, generation_tracker: Hive::Conditions::GenerationTracker.new)
        @task = task
        @cfg = cfg
        @attempt_store = attempt_store || default_attempt_store
        @event_builder = EventBuilder.new(task: task, attempt_store: @attempt_store)
        @writer = writer || Hive::TaskJournal::Writer.new(
          task_folder: task.folder, attempt_store: @attempt_store
        )
        @projection_store = projection_store || Hive::TaskProjection::Store.new(
          task_folder: task.folder, attempt_store: @attempt_store
        )
        @resolver = resolver || Resolver.new(cfg: cfg)
        @generation_tracker = generation_tracker
      end

      def capture_execute!
        context = context!
        if (existing = projected_execute(context.task_generation))
          return selection_from_projection(existing)
        end

        selection = @resolver.resolve_execute(
          generation: context.task_generation, attempt_id: context.attempt_id
        )
        ensure_generation_event!(context)
        @writer.append_idempotent(
          identity_event("implementation_identity_captured", selection, context,
                         reason: "execute_identity_captured"),
          idempotency_key: identity_key(context.task_generation)
        )
        @projection_store.rebuild!
        selection_from_projection(projected_execute(context.task_generation))
      end

      def projected_execute(generation)
        identity = @projection_store.read["implementation_identity"]
        execute = identity && identity["execute"]
        execute if execute && execute["generation"] == generation
      end

      def ensure_execute!
        context = context!
        return selection_from_projection(projected_execute(context.task_generation)) if projected_execute(context.task_generation)

        require "hive/implementation_identity/reconstructor"
        Reconstructor.new(
          task: @task, cfg: @cfg, attempt_store: @attempt_store,
          writer: @writer, projection_store: @projection_store, resolver: @resolver
        ).reconstruct!
      end

      def resolve_stage!(stage)
        stage = stage.to_s
        unless Resolver::DOWNSTREAM_EFFORT.key?(stage)
          raise ResolutionError, "#{stage.inspect} is not an implementation-owning downstream stage"
        end

        context = context!
        if (existing = projected_stage(stage, context.task_generation))
          return selection_from_projection(existing)
        end

        execute = ensure_execute!
        selection = @resolver.resolve_stage(
          stage, execute_identity: execute, attempt_id: context.attempt_id
        )
        begin
          @writer.append_idempotent(
            identity_event("implementation_stage_resolved", selection, context,
                           reason: "implementation_stage_resolved"),
            idempotency_key: "#{task_key}/#{context.task_generation}/#{stage}"
          )
        rescue Hive::TaskJournal::Conflict
          @projection_store.rebuild!
          existing = projected_stage(stage, context.task_generation)
          raise unless existing

          return selection_from_projection(existing)
        end
        @projection_store.rebuild!
        selection
      end

      def observe_route!(stage:, requested_route:, actual_route:,
                         resolution_status:, outcome_kind:, usage:,
                         observation_id: nil)
        stage = stage.to_s
        unless Resolver::IMPLEMENTATION_STAGES.include?(stage)
          raise ResolutionError,
                "#{stage.inspect} is not an implementation-owning stage"
        end

        context = context!
        selected = stage == "execute" ?
          projected_execute(context.task_generation) :
          projected_stage(stage, context.task_generation)
        unless selected
          raise ResolutionError,
                "#{stage} implementation identity must be persisted before observation"
        end
        support = Hive::AgentSupport.for(selected.fetch("provider"))
        unless support&.const_defined?(:Observation, false)
          raise InvalidIdentity,
                "#{selected.fetch("provider")} does not support route observations"
        end
        policy = support.const_get(:Observation, false)
        observation = policy.build(
          selected:, stage:, generation: context.task_generation,
          requested_route:, actual_route:, resolution_status:, outcome_kind:, usage:
        )
        identity = observation_id.to_s
        if identity.empty?
          identity = Digest::SHA256.hexdigest(JSON.generate(observation)).slice(0, 24)
        elsif !identity.match?(/\A[A-Za-z0-9._:-]+\z/)
          raise InvalidIdentity, "invalid route observation identity"
        end
        provenance = policy.provenance(observation)
        @writer.append_idempotent(
          @event_builder.build(
            context,
            event_type: "implementation_identity_observed",
            reason: provenance.fetch("reason"),
            provenance: { "source" => provenance.fetch("source") },
            payload: { "observation" => observation }
          ),
          idempotency_key: [
            task_key, context.task_generation, stage, context.attempt_id,
            provenance.fetch("namespace"), identity
          ].join("/")
        )
        @projection_store.rebuild!
        observation
      end

      # Materialization itself is owned by Resolver#materialize_persisted so
      # projection reads and legacy reconstruction cannot diverge.
      def selection_from_projection(identity)
        @resolver.materialize_persisted(identity)
      end

      def projected_stage(stage, generation)
        identity = @projection_store.read["implementation_identity"]
        selected = identity&.dig("stages", stage.to_s)
        selected if selected && selected["generation"] == generation
      end

      private

      def ensure_generation_event!(context)
        records = Hive::TaskProjection.read_journal(@writer.path)
        decision = @generation_tracker.resolve(
          task: @task, records: records, workflow_policy: workflow_policy
        )
        unless decision.task_generation == context.task_generation
          raise Hive::Conditions::GenerationMismatch,
                "attempt #{context.attempt_id} owns generation #{context.task_generation}, " \
                "but current inputs require #{decision.task_generation}"
        end
        return unless decision.advanced

        @writer.append_idempotent(
          @event_builder.build(
            context, event_type: "generation_advanced", reason: decision.reason,
            payload: {
              "input_fingerprint" => decision.input_fingerprint,
              "invalidation_token" => decision.invalidation_token
            }
          ),
          idempotency_key: "#{task_key}/#{context.task_generation}/generation"
        )
      end

      def identity_event(event_type, selection, context, reason:)
        @event_builder.build(
          context, event_type: event_type, reason: reason,
          provenance: { "source" => selection.source },
          payload: { "identity" => persisted_identity(selection) }
        )
      end

      def persisted_identity(selection)
        selection.to_h.reject { |key, _| key == "native_arguments" }
      end

      def identity_key(generation)
        "#{task_key}/#{generation}/execute-identity"
      end

      def task_key
        task_id ? "id:#{task_id}" : "slug:#{@task.slug}"
      end

      def task_id
        @task.respond_to?(:id) ? @task.id&.to_s : nil
      end

      def workflow_policy
        return {} unless @task.respond_to?(:workflow)

        @task.workflow&.stage_named("execute")&.condition_policy&.to_h || {}
      end

      def context!
        Hive::Attempts::Context.current ||
          raise(ResolutionError, "implementation identity capture requires a durable attempt context")
      end

      def default_attempt_store
        Hive::Attempts::Repository.runtime
      end
    end
  end
end
