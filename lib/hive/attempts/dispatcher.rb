require "securerandom"
require "hive/attempts/contracts"
require "hive/attempts/capability"
require "hive/attempts/capacity_snapshot"
require "hive/attempts/generation"
require "hive/provider_health"
require "hive/provider_routing"
require "hive/task_resolver"
require "hive/workflows"

module Hive
  module Attempts
    class Dispatcher
      BRAINSTORM_STAGE_DIR = "2-brainstorm".freeze # coding-scoped: coding brainstorm artifact repair

      DEFAULT_LIMITS = { max_global: 3, max_per_project: 3, max_daily: 50 }.freeze

      def initialize(store:, launcher:, limits: DEFAULT_LIMITS, clock: -> { Time.now.utc },
                     id_generator: -> { SecureRandom.uuid }, task_resolver: nil,
                     capability_generator: Capability.method(:generate),
                     launch_timeout_sec: 30, routing_policy_resolver: nil,
                     health_store: nil, health_store_factory: nil,
                     router: Hive::ProviderRouting::Router.new,
                     decision_id_generator: -> { SecureRandom.uuid })
        @store = store
        @launcher = launcher
        @limits = DEFAULT_LIMITS.merge(limits)
        @clock = clock
        @id_generator = id_generator
        @capability_generator = capability_generator
        @task_resolver = task_resolver || method(:resolve_request_task)
        @launch_timeout_sec = launch_timeout_sec
        @routing_policy_resolver = routing_policy_resolver || method(:legacy_policy_for)
        @health_store = health_store
        @health_store_factory = health_store_factory || method(:open_health_store)
        @router = router
        @decision_id_generator = decision_id_generator
      end

      def dispatch(task:, project:, intended_stage:, argv:, request_id:, provider:,
                   interactive: false, generation: nil, predecessor_attempt_id: nil,
                   inherited_outputs: [], retry_charge: 0, now: @clock.call,
                   admission_view: nil, routing_policy: nil)
        @launcher.preflight!
        generation = normalize_generation(
          generation, task: task, project: project, intended_stage: intended_stage
        )
        admit(
          task: task, generation: generation, argv: argv, request_id: request_id,
          provider: provider, interactive: interactive,
          predecessor_attempt_id: predecessor_attempt_id,
          inherited_outputs: inherited_outputs, retry_charge: retry_charge,
          successor_of: nil, now: now, admission_view: admission_view,
          routing_policy: routing_policy || resolve_routing_policy(task, intended_stage)
        )
      end

      def dispatch_successor(predecessor:, task:, project:, argv:, request_id:, provider:,
                             inherited_outputs: nil, retry_charge: nil, interactive: false,
                             now: @clock.call, admission_view: nil, routing_policy: nil)
        @launcher.preflight!
        generation = Generation.resolve(
          task: task,
          project: project,
          intended_stage: predecessor["intended_stage"],
          # A recovery successor retains the predecessor's logical generation
          # (and therefore its frozen routing policy), while fencing its
          # worker to the exact post-recovery-clear task bytes admitted now.
          progress_token: Generation.artifact_token(task),
          task_generation: predecessor.task_generation,
          attempt_store: @store
        )
        inherited = if inherited_outputs.nil? || inherited_outputs.empty?
          (predecessor["inherited_outputs"] + predecessor["current_outputs"]).uniq
        else
          inherited_outputs
        end
        admit(
          task: task, generation: generation, argv: argv, request_id: request_id,
          provider: provider, interactive: interactive,
          predecessor_attempt_id: predecessor.attempt_id,
          inherited_outputs: inherited,
          retry_charge: retry_charge.nil? ? predecessor["retry_charge"] : retry_charge,
          successor_of: predecessor.attempt_id, now: now,
          admission_view: admission_view,
          routing_policy: routing_policy || resolve_routing_policy(task, predecessor["intended_stage"])
        )
      end

      # Admit a first-class module-hook subject through the same capacity,
      # lease, handoff, and retry substrate as task-stage attempts. The
      # caller owns hook enabled/cursor/deduplication serialization; this
      # method owns host-wide attempt capacity and durable process handoff.
      def dispatch_module_hook(generation:, subject:, argv:, request_id:, provider:,
                               interactive: false, predecessor_attempt_id: nil,
                               inherited_outputs: [], retry_charge: 0, now: @clock.call,
                               project_root: nil, admission_view: nil, routing_policy: nil)
        @launcher.preflight!
        admit(
          task: nil, generation: generation, argv: argv, request_id: request_id,
          provider: provider, interactive: interactive,
          predecessor_attempt_id: predecessor_attempt_id,
          inherited_outputs: inherited_outputs, retry_charge: retry_charge,
          successor_of: nil, subject: subject, now: now,
          admission_view: admission_view,
          routing_policy: routing_policy || resolve_routing_policy(nil, generation.intended_stage)
        )
      end

      def dispatch_request(request, interactive: false, now: @clock.call,
                           admission_view: nil)
        task = @task_resolver.call(request)
        intended_stage = intended_stage_for(request.argv, task)
        generation = Generation.resolve(
          task: task, project: request.project, intended_stage: intended_stage,
          task_generation: request.respond_to?(:task_generation) ? request.task_generation : nil,
          attempt_store: @store
        )
        predecessor_id = request.respond_to?(:predecessor_attempt_id) ? request.predecessor_attempt_id : nil
        predecessor = predecessor_id && @store.fetch(predecessor_id)
        return dispatch_successor(
          predecessor: predecessor, task: task, project: request.project, argv: request.argv,
          request_id: request.request_id, provider: provider_for(task),
          inherited_outputs: request.inherited_outputs,
          retry_charge: recovery_retry_charge(request), interactive: interactive,
          now: now, admission_view: admission_view
        ) if successor_predecessor?(predecessor)

        dispatch(
          task: task, project: request.project, intended_stage: intended_stage,
          argv: request.argv, request_id: request.request_id, provider: provider_for(task),
          interactive: interactive, generation: generation,
          inherited_outputs: request.respond_to?(:inherited_outputs) ? request.inherited_outputs : [],
          now: now, admission_view: admission_view
        )
      end

      private

      def admit(task:, generation:, argv:, request_id:, provider:, interactive:,
                predecessor_attempt_id:, inherited_outputs:, retry_charge:, successor_of:, now:,
                subject: nil, admission_view: nil, routing_policy:)
        result = nil
        created = nil
        claim_capability = nil
        route_decision = nil
        view = admission_view
        # Fixed lock order: global admission, then task generation. The outer
        # lock makes the capacity snapshot and reservation one host-wide
        # transaction even when concurrent requests have different generations.
        @store.with_admission_lock do
          @store.with_generation_lock(generation.task_generation) do
            view ||= AdmissionView.new(store: @store, hot_scan: @store.scan)
            records = view.refresh_for_admission
            semantic_owner = find_semantic_owner(records, generation)
            if semantic_owner&.live?
              result = live_result(semantic_owner, interactive: interactive)
              next
            end

            exact = records.select { |record| record.task_generation == generation.task_generation }
            terminal = if successor_of.nil?
              replayable_terminal(
                exact, request_id, task: task, admission_view: view,
                generation: generation, subject: subject
              )
            end
            if terminal
              result = DispatchResult.new(
                status: :terminal_replay, attempt: terminal, receipt: terminal.receipt,
                attach_descriptor: nil, reason: nil
              )
              next
            end

            lost = unresolved_lost_attempts(
              admission_view: view, generation: generation, subject: subject
            )
            predecessor = successor_of &&
                          view.find(successor_of)
            if successor_of && !successor_predecessor?(predecessor)
              result = DispatchResult.new(
                status: :deferred, attempt: predecessor, receipt: nil,
                attach_descriptor: nil, reason: "invalid_predecessor"
              )
              next
            end
            existing_successor = successor_of && view.successor(
              predecessor_attempt_id: successor_of
            )
            if existing_successor
              result = DispatchResult.new(
                status: :deferred, attempt: existing_successor, receipt: nil,
                attach_descriptor: nil, reason: "successor_exists"
              )
              next
            end
            if successor_of.nil? && lost.any?
              result = DispatchResult.new(
                status: :deferred, attempt: lost.last, receipt: nil,
                attach_descriptor: nil, reason: "attempt_lost"
              )
              next
            end

            durable_subject = subject || task_subject(generation)
            frozen_policy = @store.routing_policies.fetch_or_store(
              ownership_generation: generation.ownership_generation,
              subject: durable_subject,
              policy: routing_policy
            )

            snapshot = view.capacity(now: now, records: records)
            utc_date = now.utc.to_date
            if snapshot.at_limit?(
              project: generation.project, task_slug: generation.task_slug, date: utc_date,
              max_global: @limits.fetch(:max_global),
              max_per_project: @limits.fetch(:max_per_project),
              max_daily: @limits.fetch(:max_daily)
            )
              result = DispatchResult.new(
                status: :deferred, attempt: nil, receipt: nil,
                attach_descriptor: nil, reason: "capacity"
              )
              next
            end

            if frozen_policy.explicit?
              health = provider_health_store
              health.reconcile!
              stale_retries = 0
              loop do
                route_decision = select_provider_route(
                  policy: frozen_policy,
                  health: health,
                  snapshot: snapshot,
                  records: records,
                  generation: generation,
                  now: now
                )
                unless route_decision.selected?
                  view.record_routing_decision(
                    decision: route_decision,
                    task_generation: generation.task_generation,
                    subject: durable_subject,
                    project: generation.project
                  )
                  result = DispatchResult.new(
                    status: route_decision.capacity_saturated? ? :deferred : :no_route,
                    attempt: nil,
                    receipt: nil,
                    attach_descriptor: nil,
                    reason: route_decision.reason,
                    decision: route_decision
                  )
                  break
                end

                claim_capability = @capability_generator.call
                attempt_id = @id_generator.call
                selected = route_decision.candidates.find(&:eligible?)
                intent = if route_decision.probe_requirements.empty?
                  nil
                else
                  Hive::ProviderHealth::ProbeIntent.new(
                    intent_id: route_decision.decision_id,
                    attempt_id: attempt_id,
                    task_generation: generation.task_generation,
                    ownership_fence: generation.ownership_generation,
                    requirements: route_decision.probe_requirements
                  )
                end
                created = health.with_route_admission(
                  evaluation: selected.health,
                  intent: intent
                ) do |probe_bindings|
                  persist_launching_attempt(
                    view: view,
                    attempt_id: attempt_id,
                    request_id: request_id,
                    predecessor_attempt_id: predecessor_attempt_id,
                    task: task,
                    generation: generation,
                    argv: argv,
                    provider: route_decision.adapter,
                    routing: explicit_routing(route_decision, probe_bindings),
                    claim_capability: claim_capability,
                    retry_charge: retry_charge,
                    inherited_outputs: inherited_outputs,
                    subject: subject,
                    now: now
                  )
                end
                view.record_routing_decision(
                  decision: route_decision,
                  task_generation: generation.task_generation,
                  subject: durable_subject,
                  project: generation.project,
                  attempt_id: created.attempt_id
                )
                break
              rescue Hive::ProviderHealth::StaleGeneration
                raise if created

                stale_retries += 1
                raise if stale_retries >= 3

                health.reconcile!
              end
              next if result
            else
              claim_capability = @capability_generator.call
              attempt_id = @id_generator.call
              created = persist_launching_attempt(
                view: view,
                attempt_id: attempt_id,
                request_id: request_id,
                predecessor_attempt_id: predecessor_attempt_id,
                task: task,
                generation: generation,
                argv: argv,
                provider: provider.to_s,
                routing: { "mode" => "legacy" },
                claim_capability: claim_capability,
                retry_charge: retry_charge,
                inherited_outputs: inherited_outputs,
                subject: subject,
                now: now
              )
            end
          end
        end

        return result if result

        handoff = @launcher.launch(created, claim_capability: claim_capability)
        if handoff.is_a?(Hash) && (handoff["claimed"] == true || handoff["state"] == "launching")
          return accepted_result(created, interactive: interactive, decision: route_decision)
        end

        resolve_failed_handoff(
          created, interactive: interactive,
          error: handoff.is_a?(Hash) ? handoff["error"] : nil,
          admission_view: view
        )
      rescue StandardError => e
        raise unless created

        resolve_failed_handoff(
          created, interactive: interactive, error: "#{e.class}: #{e.message}",
          admission_view: view
        )
      end

      # Request IDs own delivery idempotency: replaying the same request must
      # keep returning its original receipt, including a failure. A different
      # request is a deliberate retry, so only a successful terminal receipt
      # remains the semantic owner of the unchanged generation.
      def replayable_terminal(records, request_id, task:, admission_view: nil,
                              generation: nil, subject: nil)
        terminals = records.select { |record| record.state == "terminal" }
        if admission_view
          point_subject = subject || task_subject(generation)
          terminals |= [
            admission_view.terminal_attempt(request_id: request_id),
            admission_view.successful_attempt(
              task_generation: generation.task_generation,
              subject: point_subject
            )
          ].compact
        end
        terminals = ordered_records(terminals)
        same_request = terminals.select { |record| record["request_id"] == request_id }
        if brainstorm_artifact_missing?(task, terminals)
          # A failed receipt remains idempotent for its request even before
          # the legacy success is considered.
          same_request_failure = same_request.reverse.find { |record| record.outcome != "succeeded" }
          return same_request_failure if same_request_failure
        end

        unless same_request.empty?
          newest = same_request.last
          return newest unless newest.outcome == "succeeded"
          return newest if required_artifact_valid?(task, newest)
        end

        terminals.reverse.find do |record|
          record.outcome == "succeeded" && required_artifact_valid?(task, record)
        end
      end

      def brainstorm_artifact_missing?(task, records)
        return false unless coding_brainstorm?(task)

        record = records.find { |candidate| candidate["intended_stage"] == BRAINSTORM_STAGE_DIR }
        record && !required_artifact_valid?(task, record)
      end

      def required_artifact_valid?(task, record)
        return true unless coding_brainstorm?(task) &&
                           record["intended_stage"] == BRAINSTORM_STAGE_DIR

        require "hive/stages/brainstorm"
        Hive::Stages::Brainstorm.artifact_valid?(task.state_file)
      end

      def coding_brainstorm?(task)
        Hive::Workflows.coding_id?(task.respond_to?(:workflow) ? task.workflow : nil)
      end

      # A lost attempt blocks ordinary admission only until its explicit
      # successor exists. Once that descendant terminalizes unsuccessfully, a
      # new error-retry request must not be trapped behind the older resolved
      # loss forever.
      def unresolved_lost_attempts(admission_view:, generation:,
                                   subject: nil)
        unresolved = admission_view.unresolved_loss(
          task_generation: generation.task_generation,
          subject: subject || task_subject(generation)
        )
        unresolved ? [ unresolved ] : []
      end

      def successor_predecessor?(record)
        return false unless record
        return true if record.state == "lost"
        return false unless record.state == "terminal" && record.outcome == "failed"
        return false unless record.explicit_routing?

        record.receipt&.fetch("provider_evidence", nil).is_a?(Hash)
      end

      def recovery_retry_charge(request)
        return nil unless request.respond_to?(:recovery) && request.recovery.is_a?(Hash)

        request.recovery["retry_count"]
      end

      def task_subject(generation)
        Record.task_stage_subject(
          task_id: generation.task_id&.to_s,
          task_slug: generation.task_slug,
          intended_stage: generation.intended_stage
        )
      end

      def ordered_records(records)
        records.sort_by do |record|
          [ record["accepted_at"], record.lease_version, record.attempt_id ]
        end
      end

      def find_semantic_owner(records, generation)
        candidates = records.select do |record|
          if generation.respond_to?(:subject) && generation.subject
            next record.subject == generation.subject && record.live?
          end
          same_task = if generation.task_id.nil?
            record["project"] == generation.project && record["task_slug"] == generation.task_slug
          else
            record["task_id"].to_s == generation.task_id.to_s
          end
          same_task && record["intended_stage"] == generation.intended_stage && record.live?
        end
        candidates.max_by { |record| [ record["accepted_at"], record.lease_version ] }
      end

      def live_result(record, interactive:)
        DispatchResult.new(
          status: :existing_live, attempt: record, receipt: nil,
          attach_descriptor: interactive ? attach_descriptor(record) : nil,
          reason: nil
        )
      end

      def accepted_result(record, interactive:, decision: nil)
        DispatchResult.new(
          status: :accepted, attempt: record, receipt: nil,
          attach_descriptor: interactive ? attach_descriptor(record) : nil,
          reason: nil, decision: decision
        )
      end

      def resolve_failed_handoff(created, interactive:, error: nil,
                                 admission_view: nil)
        current = @store.fetch_hot(created.attempt_id)
        admission_view&.record(current) if current
        adopted = result_for_adopted_handoff(current, interactive: interactive)
        return adopted if adopted
        return deferred_handoff_result(current) if current&.state == "lost"

        diagnostics = {}
        diagnostics["launch_handoff_error"] = error.to_s[0, 1_000] unless error.to_s.empty?
        lost = @store.mark_lost(
          current || created,
          reason: "launch_handoff_failed",
          diagnostics: diagnostics,
          now: @clock.call
        )
        admission_view&.record(lost)
        deferred_handoff_result(lost)
      rescue CompareAndSwapFailed
        current = @store.fetch_hot(created.attempt_id)
        admission_view&.record(current) if current
        result_for_adopted_handoff(current, interactive: interactive) || deferred_handoff_result(current)
      end

      def result_for_adopted_handoff(record, interactive:)
        return nil unless record
        return accepted_result(record, interactive: interactive) if record.state == "running" || record.claimed?
        if record.state == "terminal"
          return DispatchResult.new(
            status: :terminal_replay, attempt: record, receipt: record.receipt,
            attach_descriptor: interactive ? attach_descriptor(record) : nil,
            reason: nil
          )
        end

        nil
      end

      def deferred_handoff_result(record)
        DispatchResult.new(
          status: :deferred, attempt: record, receipt: nil,
          attach_descriptor: nil, reason: "launch_handoff_failed"
        )
      end

      def attach_descriptor(record)
        { "attempt_id" => record.attempt_id }
      end

      def normalize_generation(generation, task:, project:, intended_stage:)
        return generation if generation.is_a?(Generation)

        Generation.resolve(
          task: task, project: project, intended_stage: intended_stage,
          task_generation: generation, attempt_store: @store
        )
      end

      def starting_revision(task)
        return nil unless task

        worktree = task.respond_to?(:worktree_path) ? task.worktree_path : nil
        return nil unless worktree && File.directory?(worktree)

        IO.popen([ "git", "-C", worktree, "rev-parse", "HEAD" ], err: File::NULL, &:read).strip.then do |value|
          value.empty? ? nil : value
        end
      rescue SystemCallError
        nil
      end

      def resolve_request_task(request)
        Hive::TaskResolver.new(request.slug, project_filter: request.project).resolve
      end

      def provider_for(task)
        stage = task.stage_name.to_s.tr("-", "_")
        Hive::Config.load(task.project_root).dig(stage, "agent") || "claude"
      end

      def resolve_routing_policy(task, intended_stage)
        policy = @routing_policy_resolver.call(task, intended_stage)
        unless policy.is_a?(Hive::ProviderRouting::Policy)
          raise Hive::ConfigError, "routing policy resolver returned an invalid policy"
        end

        policy
      end

      def legacy_policy_for(_task, intended_stage)
        Hive::ProviderRouting::Policy.legacy(stage: routing_stage_name(intended_stage))
      end

      def routing_stage_name(intended_stage)
        intended_stage.to_s.sub(/\A\d+-/, "").tr("-", "_")
      end

      def provider_health_store
        @health_store ||= @health_store_factory.call
      end

      def open_health_store
        Hive::ProviderHealth.open(attempt_reader: method(:health_attempt_state))
      end

      def health_attempt_state(attempt_id)
        record = @store.fetch_hot(attempt_id)
        return nil unless record

        {
          "attempt_id" => record.attempt_id,
          "task_generation" => record.task_generation,
          "ownership_fence" => record["ownership_generation"],
          "state" => record.state,
          "probe_bindings" => record["routing"].fetch("probe_bindings", [])
        }
      rescue Hive::Attempts::StoreError
        nil
      end

      def select_provider_route(policy:, health:, snapshot:, records:, generation:, now:)
        evaluations = policy.eligible_routes.to_h do |route|
          [
            route.id,
            health.evaluate_route(
              account_id: route.account,
              model_id: route.model,
              now: now
            )
          ]
        end
        capacity = snapshot.provider_account_capacity(
          policy: policy,
          records: records
        )
        request = Hive::ProviderRouting::Request.new(
          policy: policy,
          task_generation: generation.task_generation,
          health: evaluations,
          capacity: capacity
        )
        @router.call(
          request: request,
          decision_id: @decision_id_generator.call,
          decided_at: now
        )
      end

      def persist_launching_attempt(view:, attempt_id:, request_id:, predecessor_attempt_id:,
                                    task:, generation:, argv:, provider:, routing:,
                                    claim_capability:, retry_charge:, inherited_outputs:,
                                    subject:, now:)
        view.reserve_live(
          attempt_id: attempt_id,
          project: generation.project,
          task_slug: generation.task_slug
        )
        record = @store.create_launching(
          attempt_id: attempt_id,
          request_id: request_id,
          predecessor_attempt_id: predecessor_attempt_id,
          task_id: generation.task_id&.to_s,
          project: generation.project,
          task_slug: generation.task_slug,
          intended_stage: generation.intended_stage,
          task_generation: generation.task_generation,
          ownership_generation: generation.ownership_generation,
          task_input_epoch: generation.task_input_epoch,
          progress_token: generation.progress_token,
          provider: provider,
          routing: routing,
          worker_argv: argv,
          claim_capability_digest: Capability.digest(claim_capability),
          starting_revision: starting_revision(task),
          retry_charge: retry_charge,
          inherited_outputs: inherited_outputs || [],
          subject: subject,
          launch_timeout_sec: @launch_timeout_sec,
          now: now
        )
        view.confirm_live(record)
        view.record(record)
      end

      def explicit_routing(decision, probe_bindings)
        route = decision.route
        {
          "mode" => "explicit",
          "policy_digest" => decision.policy_digest,
          "decision" => decision.to_record_h,
          "route" => {
            "route_id" => route.id,
            "provider_account_id" => route.account,
            "adapter" => route.adapter,
            "launch_binding_id" => route.launch_binding,
            "model" => route.model,
            "effort" => route.effort
          },
          "circuit_generations" => decision.circuit_generations,
          "probe_bindings" => Array(probe_bindings).map(&:to_h)
        }
      end

      def intended_stage_for(argv, task)
        verb = Array(argv)[1].to_s
        return "#{task.stage_index}-#{task.stage_name}" if verb == "run"

        Hive::Workflows.for_verb(verb).fetch(:target)
      rescue KeyError, Hive::Error
        "#{task.stage_index}-#{task.stage_name}"
      end
    end
  end
end
