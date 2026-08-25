require "hive/attempts/context"
require "hive/attempts/store"
require "hive/conditions/generation_tracker"
require "hive/implementation_identity/event_builder"
require "hive/implementation_identity/resolver"
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

      def observe_opencode!(stage:, requested_route:, actual_route:,
                            resolution_status:, outcome_kind:, usage:,
                            observation_id: nil)
        stage = stage.to_s
        unless Resolver::IMPLEMENTATION_STAGES.include?(stage)
          raise ResolutionError,
                "#{stage.inspect} is not an implementation-owning stage"
        end

        context = context!
        selected = if stage == "execute"
          projected_execute(context.task_generation)
        else
          projected_stage(stage, context.task_generation)
        end
        unless selected
          raise ResolutionError,
                "#{stage} implementation identity must be persisted before observation"
        end
        unless selected.fetch("provider") == "opencode"
          raise InvalidIdentity,
                "OpenCode observations require an opencode implementation identity"
        end

        requested = AgentCliRuntime::Route.parse(requested_route)
        unless requested.to_s == selected.fetch("model")
          raise InvalidIdentity,
                "observed requested route does not match persisted implementation identity"
        end
        identity = AgentCliRuntime::RouteIdentity.new(
          requested: requested, actual: actual_route,
          resolution_status: resolution_status
        )
        validate_observed_route_identity!(identity)
        kind = outcome_kind.to_sym
        unless AgentCliRuntime::KINDS.include?(kind)
          raise InvalidIdentity, "invalid OpenCode outcome kind #{outcome_kind.inspect}"
        end
        normalized_usage = normalize_observed_usage(usage)
        observation = {
          "stage" => stage,
          "generation" => context.task_generation,
          "requested_backend" => identity.requested.provider,
          "requested_model" => identity.requested.model,
          "actual_backend" => identity.actual&.provider,
          "actual_model" => identity.actual&.model,
          "route_resolution_status" => identity.resolution_status.to_s,
          "outcome_kind" => kind.to_s,
          "usage" => normalized_usage&.to_h&.transform_keys(&:to_s)
        }

        observation_identity = observation_id.to_s
        if observation_identity.empty?
          observation_identity = Digest::SHA256.hexdigest(
            JSON.generate(observation)
          ).slice(0, 24)
        elsif !observation_identity.match?(/\A[A-Za-z0-9._:-]+\z/)
          raise InvalidIdentity, "invalid OpenCode observation identity"
        end
        @writer.append_idempotent(
          @event_builder.build(
            context,
            event_type: "implementation_identity_observed",
            reason: "opencode_route_observed",
            provenance: {
              "source" => identity.actual ?
                "opencode_sanitized_export" : "opencode_run"
            },
            payload: { "observation" => observation }
          ),
          idempotency_key:
            "#{task_key}/#{context.task_generation}/#{stage}/#{context.attempt_id}/" \
            "opencode-observation/#{observation_identity}"
        )
        @projection_store.rebuild!
        observation.freeze
      rescue ArgumentError => e
        raise InvalidIdentity, "invalid OpenCode observation: #{e.message}", cause: e
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

      def validate_observed_route_identity!(identity)
        valid = case identity.resolution_status
        when :unobserved
          identity.actual.nil?
        when :matched
          identity.actual == identity.requested
        when :resolved_differently
          !identity.actual.nil? && identity.actual != identity.requested
        end
        return if valid

        raise InvalidIdentity,
              "OpenCode route resolution status contradicts observed route evidence"
      end

      def normalize_observed_usage(usage)
        return nil if usage.nil?
        return usage if usage.is_a?(AgentCliRuntime::NormalizedUsage)

        values = Hive::StringifyKeys.call(usage)
        allowed = %w[input output cache_read cache_write reasoning cost]
        unknown = values.keys - allowed
        unless unknown.empty?
          raise InvalidIdentity,
                "unknown OpenCode usage fields: #{unknown.sort.join(', ')}"
        end
        AgentCliRuntime::NormalizedUsage.new(
          **allowed.to_h { |key| [ key.to_sym, values[key] ] }
        )
      end

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
        root = ENV["HIVE_ATTEMPT_STORE_ROOT"].to_s
        root.empty? ? Hive::Attempts::Store.new : Hive::Attempts::Store.new(root: root)
      end
    end
  end
end
