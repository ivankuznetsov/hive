require "hive/attempts/context"
require "hive/attempts/store"
require "hive/conditions/generation_tracker"
require "hive/implementation_identity/resolver"
require "hive/task_journal"
require "hive/task_projection/store"

module Hive
  module ImplementationIdentity
    class Store
      def initialize(task:, cfg:, attempt_store: nil, writer: nil, projection_store: nil,
                     resolver: nil, generation_tracker: Hive::Conditions::GenerationTracker.new)
        @task = task
        @cfg = cfg
        @attempt_store = attempt_store || default_attempt_store
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

        ensure_generation_event!(context)
        selection = @resolver.resolve_execute(
          generation: context.task_generation, attempt_id: context.attempt_id
        )
        @writer.append_idempotent(
          identity_event("implementation_identity_captured", selection, context,
                         reason: "execute_identity_captured"),
          idempotency_key: identity_key(context.task_generation)
        )
        @projection_store.rebuild!
        selection_from_projection(projected_execute(context.task_generation))
      end

      def projected_execute(generation = current_generation)
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
        context = context!
        execute = ensure_execute!
        selection = @resolver.resolve_stage(
          stage, execute_identity: execute, attempt_id: context.attempt_id
        )
        @writer.append_idempotent(
          identity_event("implementation_stage_resolved", selection, context,
                         reason: "implementation_stage_resolved"),
          idempotency_key: "#{task_key}/#{context.task_generation}/#{stage}/#{context.attempt_id}"
        )
        @projection_store.rebuild!
        selection
      end

      def current_generation
        @projection_store.read.dig("implementation_identity", "generation") || 0
      end

      def selection_from_projection(identity)
        profile = Hive::AgentProfiles.lookup(identity.fetch("provider"), cfg: @cfg)
        arguments = profile.identity_arguments(
          model: identity.fetch("model"), effort: identity["requested_effort"],
          pin_model: identity.fetch("model_pinned", true)
        )
        Selection.new(
          stage: identity.fetch("stage"), provider: identity.fetch("provider"),
          model: identity.fetch("model"), profile_name: identity.fetch("profile_name"),
          launcher_identity: identity.fetch("launcher_identity"), source: identity.fetch("source"),
          generation: identity.fetch("generation"),
          originating_attempt: identity["originating_attempt"],
          requested_effort: identity["requested_effort"],
          effective_effort: identity["effective_effort"],
          effort_supported: identity["effort_supported"],
          model_pinned: identity.fetch("model_pinned", true),
          native_arguments: arguments.native_arguments
        )
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
          base_event(
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
        base_event(
          context, event_type: event_type, reason: reason,
          provenance: { "source" => selection.source },
          payload: { "identity" => persisted_identity(selection) }
        )
      end

      def base_event(context, event_type:, reason:, provenance: { "source" => "generation_resolver" },
                     payload: {})
        attempt = @attempt_store.fetch(context.attempt_id)
        raise ResolutionError, "durable attempt #{context.attempt_id.inspect} is unavailable" unless attempt

        {
          event_type: event_type,
          task: { "id" => task_id, "slug" => @task.slug.to_s },
          workflow: "coding",
          stage: attempt["intended_stage"],
          attempt_id: context.attempt_id,
          task_generation: context.task_generation,
          ownership_generation: context.ownership_generation,
          commit_generation: 0,
          reason: reason,
          evidence: [ { "type" => "attempt_lease", "attempt_id" => context.attempt_id } ],
          provenance: provenance,
          payload: payload
        }
      end

      def persisted_identity(selection)
        selection.to_h.reject { |key, _| key == "native_arguments" }
      end

      def projected_identity
        @projection_store.read["implementation_identity"]
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
        root = ENV["HIVE_ATTEMPT_STORE_ROOT"].to_s
        Hive::Attempts::Store.new(root: root.empty? ? Hive::Paths.attempts_root : root)
      end
    end
  end
end
