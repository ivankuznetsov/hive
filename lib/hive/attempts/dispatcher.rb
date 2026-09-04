require "securerandom"
require "time"
require "hive/attempts/contracts"
require "hive/attempts/capability"
require "hive/attempts/capacity_snapshot"
require "hive/attempts/generation"
require "hive/attempts/command_progress"
require "hive/runtime_identity"
require "hive/provider_routing"
require "hive/task_resolver"
require "hive/workflows"
require "hive/context_provenance"
require "hive/plan_review/store"

module Hive
  module Attempts
    class Dispatcher
      BRAINSTORM_STAGE_DIR = "2-brainstorm".freeze # coding-scoped: coding brainstorm artifact repair
      DEFAULT_LIMITS = { max_global: 3, max_per_project: 3, max_daily: 50 }.freeze
      OPERATOR_RETRY_REQUESTORS = %w[action bot cli web].freeze
      def initialize(store:, launcher:, limits: DEFAULT_LIMITS, clock: -> { Time.now.utc },
                     id_generator: -> { SecureRandom.uuid }, task_resolver: nil,
                     capability_generator: Capability.method(:generate),
                     launch_timeout_sec: 30, routing_policy_resolver: nil,
                     router: Hive::ProviderRouting::Router.new,
                     decision_id_generator: -> { SecureRandom.uuid },
                     context_provenance: Hive::ContextProvenance,
                     transient_retry_backoff_sec: 60, runtime_digest: nil)
        @store = store
        @launcher = launcher
        @limits = DEFAULT_LIMITS.merge(limits)
        @clock = clock
        @id_generator = id_generator
        @capability_generator = capability_generator
        @task_resolver = task_resolver || method(:resolve_request_task)
        @launch_timeout_sec = launch_timeout_sec
        @routing_policy_resolver = routing_policy_resolver || method(:legacy_policy_for)
        @router = router
        @decision_id_generator = decision_id_generator
        @context_provenance = context_provenance
        @transient_retry_backoff_sec = transient_retry_backoff_sec.to_i
        @runtime_digest = runtime_digest || self.class.runtime_source_digest
        unless @runtime_digest.is_a?(String) &&
               @runtime_digest.match?(Record::SHA256_PATTERN)
          raise ArgumentError, "attempt runtime digest is invalid"
        end
      end

      def self.runtime_source_digest(identity = Hive::RuntimeIdentity.new.to_h)
        Hive::RuntimeIdentity.source_digest(identity)
      end

      def dispatch(task:, project:, intended_stage:, argv:, request_id:, provider:,
                   interactive: false, generation: nil,
                   inherited_outputs: [], retry_charge: 0, now: @clock.call,
                   admission_view: nil, routing_policy: nil, retry_release: false,
                   replay_semantic_terminal: false)
        @launcher.preflight!
        generation = normalize_generation(
          generation, task: task, project: project, intended_stage: intended_stage,
          argv: argv
        )
        policy = routing_policy || resolve_routing_policy(task, intended_stage)
        result = admit(
          task: task, generation: generation, argv: argv, request_id: request_id,
          provider: provider, interactive: interactive,
          inherited_outputs: inherited_outputs, retry_charge: retry_charge,
          recovery_source_attempt_id: nil, now: now, admission_view: admission_view,
          routing_policy: policy, retry_release: retry_release,
          replay_semantic_terminal: replay_semantic_terminal,
          failed_route_id: nil
        )
        result
      end

      def dispatch_recovery(source_attempt:, task:, project:, argv:, request_id:, provider:,
                            inherited_outputs: nil, retry_charge: nil, interactive: false,
                            now: @clock.call, admission_view: nil, routing_policy: nil,
                            retry_release: false)
        @launcher.preflight!
        generation = Generation.resolve(
          task: task,
          project: project,
          intended_stage: source_attempt["intended_stage"],
          # The replacement is an independent attempt bound to the exact
          # post-clear task bytes. The numeric input epoch remains stable when
          # clearing a retryable marker does not change task inputs.
          progress_token: Generation.artifact_token(task),
          task_input_epoch: source_attempt.task_input_epoch
        )
        inherited = if inherited_outputs.nil? || inherited_outputs.empty?
          (source_attempt["inherited_outputs"] + source_attempt["current_outputs"]).uniq
        else
          inherited_outputs
        end
        admit(
          task: task, generation: generation, argv: argv, request_id: request_id,
          provider: provider, interactive: interactive,
          inherited_outputs: inherited,
          retry_charge: retry_charge.nil? ? source_attempt["retry_charge"] : retry_charge,
          recovery_source_attempt_id: source_attempt.state == "lost" ? source_attempt.attempt_id : nil,
          now: now,
          admission_view: admission_view,
          routing_policy: routing_policy || resolve_routing_policy(task, source_attempt["intended_stage"]),
          retry_release: retry_release,
          failed_route_id: failed_route_id_for(source_attempt)
        )
      end

      # Admit a first-class module-hook subject through the same capacity,
      # lease, handoff, and retry substrate as task-stage attempts. The
      # caller owns hook enabled/cursor/deduplication serialization; this
      # method owns host-wide attempt capacity and durable process handoff.
      def dispatch_module_hook(generation:, subject:, argv:, request_id:, provider:,
                               interactive: false,
                               inherited_outputs: [], retry_charge: 0, now: @clock.call,
                               project_root: nil, admission_view: nil, routing_policy: nil)
        @launcher.preflight!
        admit(
          task: nil, generation: generation, argv: argv, request_id: request_id,
          provider: provider, interactive: interactive,
          inherited_outputs: inherited_outputs, retry_charge: retry_charge,
          recovery_source_attempt_id: nil, subject: subject, now: now,
          admission_view: admission_view,
          routing_policy: routing_policy || resolve_routing_policy(nil, generation.intended_stage),
          failed_route_id: nil
        )
      end

      def dispatch_request(request, interactive: false, now: @clock.call,
                           admission_view: nil, replay_semantic_terminal: false)
        task = @task_resolver.call(request)
        intended_stage = intended_stage_for(request.argv, task)
        generation = Generation.resolve(
          task: task, project: request.project, intended_stage: intended_stage,
          progress_token: command_progress_token(request.argv, task),
          task_generation: request.respond_to?(:task_generation) ? request.task_generation : nil
        )
        source_attempt = recovery_source_attempt(request)
        return dispatch_recovery(
          source_attempt: source_attempt, task: task, project: request.project, argv: request.argv,
          request_id: request.request_id, provider: provider_for(task),
          inherited_outputs: request.inherited_outputs,
          retry_charge: recovery_retry_charge(request), interactive: interactive,
          now: now, admission_view: admission_view,
          retry_release: explicit_retry_release?(request)
        ) if recoverable_source_attempt?(source_attempt)

        dispatch(
          task: task, project: request.project, intended_stage: intended_stage,
          argv: request.argv, request_id: request.request_id, provider: provider_for(task),
          interactive: interactive, generation: generation,
          inherited_outputs: request.respond_to?(:inherited_outputs) ? request.inherited_outputs : [],
          now: now, admission_view: admission_view,
          retry_release: explicit_retry_release?(request),
          replay_semantic_terminal: replay_semantic_terminal
        )
      end

      private

      def admit(task:, generation:, argv:, request_id:, provider:, interactive:,
                inherited_outputs:, retry_charge:, recovery_source_attempt_id:, now:,
                subject: nil, admission_view: nil, routing_policy:, retry_release: false,
                replay_semantic_terminal: false, failed_route_id: nil)
        created = nil
        claim_capability = nil
        route_decision = nil
        view = admission_view
        @store.observe_task_source(task: task, generation: generation, observed_at: now) if task
        view ||= AdmissionView.new(store: @store, records: @store.active_attempts)
        records = view.records
        semantic_owner = find_semantic_owner(records, generation)
        if semantic_owner&.live?
          if semantic_owner.task_generation == generation.task_generation
            return live_result(semantic_owner, interactive: interactive)
          end

          return deferred_result("in_flight", attempt: semantic_owner)
        end

        exact = records.select { |record| record.task_generation == generation.task_generation }
        request_attempt = view.request_attempt(request_id: request_id)
        if request_attempt&.live?
          return live_result(request_attempt, interactive: interactive)
        elsif request_attempt&.state == "terminal"
          return DispatchResult.new(
            status: :terminal_replay, attempt: request_attempt,
            receipt: request_attempt.receipt, attach_descriptor: nil, reason: nil
          )
        elsif request_attempt&.state == "lost"
          return deferred_result("attempt_lost", attempt: request_attempt)
        end

        terminal = unless recovery_source_attempt_id
          replayable_terminal(
            exact, request_id, task: task, admission_view: view,
            generation: generation, subject: subject,
            replay_semantic_terminal: replay_semantic_terminal
          )
        end
        if terminal
          return DispatchResult.new(
            status: :terminal_replay, attempt: terminal, receipt: terminal.receipt,
            attach_descriptor: nil, reason: nil
          )
        end

        transient = transient_retry_terminal(
          admission_view: view, generation: generation,
          subject: subject || task_subject(generation), now: now
        )
        if transient
          return deferred_result(
            "transient_retry", attempt: transient, receipt: transient.receipt
          )
        end

        lost = unresolved_lost_attempt(
          admission_view: view, generation: generation, subject: subject
        )
        if recovery_source_attempt_id.nil? && lost
          return deferred_result("attempt_lost", attempt: lost)
        end

        snapshot = view.capacity(now: now)
        utc_date = now.utc.to_date
        if snapshot.at_limit?(
          project: generation.project, task_slug: generation.task_slug, date: utc_date,
          max_global: @limits.fetch(:max_global),
          max_per_project: @limits.fetch(:max_per_project),
          max_daily: @limits.fetch(:max_daily)
        )
          return deferred_result("capacity")
        end

        if !retry_release && CommandProgress.patrol_fix?(task) && view.patrol_retry_at(
          task_generation: generation.task_generation,
          subject: subject || task_subject(generation), runtime_digest: @runtime_digest, now: now
        )
          return deferred_result("patrol_retry_delay")
        end

        launching_attributes = {
          view: view,
          request_id: request_id,
          recovery_source_attempt_id: recovery_source_attempt_id,
          task: task,
          generation: generation,
          argv: argv,
          retry_charge: retry_charge,
          inherited_outputs: inherited_outputs,
          subject: subject,
          now: now,
          admission: patrol_admission_metadata(task: task)
        }

        if routing_policy.explicit?
          route_decision = select_provider_route(
            policy: routing_policy,
            snapshot: snapshot,
            records: records,
            generation: generation,
            now: now,
            failed_route_id: failed_route_id
          )
          unless route_decision.selected?
            return DispatchResult.new(
              status: route_decision.capacity_saturated? ? :deferred : :no_route,
              attempt: nil,
              receipt: nil,
              attach_descriptor: nil,
              reason: route_decision.reason,
              decision: route_decision
            )
          end

          claim_capability = @capability_generator.call
          attempt_id = @id_generator.call
          created = persist_launching_attempt(
            **launching_attributes,
            attempt_id: attempt_id,
            provider: route_decision.adapter,
            routing: nil,
            claim_capability: claim_capability,
            route_decision: route_decision
          )
        else
          claim_capability = @capability_generator.call
          attempt_id = @id_generator.call
          created = persist_launching_attempt(
            **launching_attributes,
            attempt_id: attempt_id,
            provider: provider.to_s,
            routing: { "mode" => "legacy" },
            claim_capability: claim_capability
          )
        end

        record_attempt_admission(task, created, now)
        capture_launch_context(task, created, generation, now)
        handoff_now = [ now.utc, @clock.call.utc ].max
        created = @store.arm_launch_handoff(
          created, launch_timeout_sec: @launch_timeout_sec, now: handoff_now
        )
        handoff = @launcher.launch(created, claim_capability: claim_capability)
        if handoff.is_a?(Hash) && (handoff["claimed"] == true || handoff["state"] == "launching")
          return accepted_result(created, interactive: interactive, decision: route_decision)
        end

        resolve_failed_handoff(
          created, interactive: interactive,
          error: handoff.is_a?(Hash) ? handoff["error"] : nil
        )
      rescue CapacityExceeded
        deferred_result("capacity")
      rescue StandardError => e
        raise unless created

        resolve_failed_handoff(
          created, interactive: interactive, error: "#{e.class}: #{e.message}"
        )
      end

      def capture_launch_context(task, attempt, generation, now)
        return unless task && task.respond_to?(:folder) && !task.folder.to_s.empty? &&
                      task.respond_to?(:project_root) && !task.project_root.to_s.empty?

        @context_provenance.capture_launch(
          task: task, attempt: attempt, generation: generation,
          attempt_store: @store, clock: -> { now }
        )
      rescue StandardError
        # Context evidence is intentionally advisory. Its own capture result is
        # partial/unavailable, while the already-durable attempt still proceeds
        # to the worker handoff.
        nil
      end

      def record_attempt_admission(task, attempt, now)
        return unless task && task.respond_to?(:folder) && !task.folder.to_s.empty?

        workflow = task.respond_to?(:workflow) ? task.workflow : nil
        workflow = workflow.id if workflow.respond_to?(:id)
        Hive::TaskActivity.new(
          task_folder: task.folder,
          task: { "id" => task.id, "slug" => task.slug },
          workflow: workflow.to_s.empty? ? "coding" : workflow.to_s,
          stage: attempt["intended_stage"], attempt_id: attempt.attempt_id,
          task_generation: attempt.task_input_epoch,
          ownership_generation: attempt.ownership_generation,
          attempt_store: @store, clock: -> { now }
        ).record(
          kind: "attempt_admitted",
          operation_id: "attempt-admitted:#{attempt.attempt_id}",
          reason: "durable attempt admitted",
          source: "attempt_dispatcher", occurred_at: now, observed_at: now,
          evidence: [
            { "kind" => "attempt_record", "reference" => "attempts/#{attempt.attempt_id}" }
          ],
          payload: {
            "provider" => attempt["provider"],
            "state" => attempt.state
          }
        )
      end

      # Request IDs own delivery idempotency: replaying the same request must
      # keep returning its original receipt, including a failure. A different
      # request is normally a deliberate retry, so only a successful terminal
      # receipt remains the semantic owner of the unchanged generation. The
      # daemon's automatic advance scan is the exception: it creates a fresh
      # delivery request on every tick, so an unchanged failed generation must
      # replay instead of spending on the same broken command forever.
      def replayable_terminal(records, request_id, task:, admission_view: nil,
                              generation: nil, subject: nil,
                              replay_semantic_terminal: false)
        terminals = records.select { |record| record.state == "terminal" }
        semantic_terminal = nil
        if admission_view
          point_subject = subject || task_subject(generation)
          semantic_terminal = admission_view.latest_terminal_attempt(
            task_generation: generation.task_generation,
            subject: point_subject
          )
          terminals |= [
            admission_view.terminal_attempt(request_id: request_id),
            semantic_terminal,
            admission_view.successful_attempt(
              task_generation: generation.task_generation,
              subject: point_subject
            )
          ].compact
        end
        terminals = ordered_records(terminals)
        if brainstorm_artifact_missing?(task, terminals)
          same_request_failure = terminals.reverse.find do |record|
            record["request_id"] == request_id && record.outcome != "succeeded"
          end
          return same_request_failure if same_request_failure
        end

        if replay_semantic_terminal && semantic_terminal&.outcome != "succeeded"
          return semantic_terminal
        end

        terminals.reverse.find do |record|
          record.outcome == "succeeded" && required_artifact_valid?(task, record)
        end
      end

      # TEMPFAIL is a scheduler collision, not an agent verdict. Preserve its
      # terminal receipt for idempotency and accounting, but pace a different
      # request from the same generation before admitting another worker.
      # The receipt timestamp makes the hold restart-safe without another
      # watcher or retry-state store.
      def transient_retry_terminal(admission_view:, generation:, subject:, now:)
        terminal = admission_view.latest_terminal_attempt(
          task_generation: generation.task_generation, subject: subject
        )
        return unless terminal&.receipt&.fetch("exit_status", nil) == Hive::ExitCodes::TEMPFAIL

        ended_at = Time.iso8601(terminal.receipt.fetch("ended_at"))
        terminal if now.utc < ended_at + @transient_retry_backoff_sec
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

      # A lost attempt blocks ordinary admission until its independent recovery
      # admission atomically records the source phase as complete.
      def unresolved_lost_attempt(admission_view:, generation:, subject: nil)
        admission_view.unresolved_loss(
          task_generation: generation.task_generation,
          subject: subject || task_subject(generation)
        )
      end

      def recoverable_source_attempt?(record)
        return false unless record
        return true if record.state == "lost"

        provider_failure_source?(record)
      end

      def provider_failure_source?(record)
        return false unless record.state == "terminal" && record.outcome == "failed"
        return false unless record.explicit_routing?

        record.receipt&.fetch("provider_evidence", nil).is_a?(Hash)
      end

      def failed_route_id_for(record)
        return unless provider_failure_source?(record)

        record["routing"].dig("route", "route_id")
      end

      def recovery_retry_charge(request)
        return nil unless request.respond_to?(:recovery) && request.recovery.is_a?(Hash)

        request.recovery["retry_count"]
      end

      def recovery_source_attempt(request)
        return unless request.respond_to?(:recovery) && request.recovery.is_a?(Hash)

        attempt_id = request.recovery.dig("source_receipt", "attempt_id")
        attempt_id && @store.fetch(attempt_id)
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

      def resolve_failed_handoff(created, interactive:, error: nil)
        current = @store.fetch_hot(created.attempt_id)
        adopted = result_for_adopted_handoff(current, interactive: interactive)
        return adopted if adopted
        if current&.state == "lost"
          return deferred_result("launch_handoff_failed", attempt: current)
        end

        diagnostics = {}
        diagnostics["launch_handoff_error"] = error.to_s[0, 1_000] unless error.to_s.empty?
        lost = @store.mark_lost(
          current || created,
          reason: "launch_handoff_failed",
          diagnostics: diagnostics,
          now: @clock.call
        )
        deferred_result("launch_handoff_failed", attempt: lost)
      rescue CompareAndSwapFailed
        current = @store.fetch_hot(created.attempt_id)
        result_for_adopted_handoff(current, interactive: interactive) ||
          deferred_result("launch_handoff_failed", attempt: current)
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

      def deferred_result(reason, attempt: nil, receipt: nil)
        DispatchResult.new(
          status: :deferred, attempt: attempt, receipt: receipt,
          attach_descriptor: nil, reason: reason
        )
      end

      def attach_descriptor(record)
        { "attempt_id" => record.attempt_id }
      end

      def normalize_generation(generation, task:, project:, intended_stage:, argv:)
        return generation if generation.is_a?(Generation)

        Generation.resolve(
          task: task, project: project, intended_stage: intended_stage,
          progress_token: command_progress_token(argv, task),
          task_generation: generation
        )
      end

      def command_progress_token(argv, task)
        base = Generation.artifact_token(task)
        Hive::Attempts::CommandProgress.token_for(argv:, task:, fallback: base)
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

      def select_provider_route(policy:, snapshot:, records:, generation:, now:,
                                failed_route_id: nil)
        capacity = CapacitySnapshot.provider_account_capacity(
          accounts: policy.account_policy, records: records,
          reserved_attempt_ids: snapshot.reserved_attempt_ids
        )
        request = Hive::ProviderRouting::Request.new(
          policy: policy,
          task_generation: generation.task_generation,
          capacity: capacity,
          failed_route_id: failed_route_id
        )
        @router.call(
          request: request,
          decision_id: @decision_id_generator.call,
          decided_at: now
        )
      end

      def persist_launching_attempt(view:, attempt_id:, request_id:, recovery_source_attempt_id:,
                                    task:, generation:, argv:, provider:, routing:,
                                    claim_capability:, retry_charge:, inherited_outputs:,
                                    subject:, now:, admission:,
                                    route_decision: nil)
        @store.create_launching(
          attempt_id: attempt_id,
          request_id: request_id,
          recovery_source_attempt_id: recovery_source_attempt_id,
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
          route_decision: route_decision,
          worker_argv: argv,
          claim_capability_digest: Capability.digest(claim_capability),
          starting_revision: starting_revision(task),
          retry_charge: retry_charge,
          inherited_outputs: inherited_outputs || [],
          subject: subject,
          source_fingerprint: generation.progress_token,
          admission: admission,
          limits: @limits,
          launch_timeout_sec: @launch_timeout_sec,
          now: now
        )
      end

      def patrol_admission_metadata(task:)
        return nil unless CommandProgress.patrol_fix?(task)

        {
          "workflow" => "patrol_fix",
          "runtime_digest" => @runtime_digest
        }
      end

      def explicit_retry_release?(request)
        request.respond_to?(:recovery) && request.recovery.is_a?(Hash) &&
          request.respond_to?(:requestor) &&
          OPERATOR_RETRY_REQUESTORS.include?(request.requestor.to_s) &&
          request.respond_to?(:trigger) && request.trigger.to_s == "recovery"
      end

      def intended_stage_for(argv, task)
        verb = Array(argv)[1].to_s
        return "#{task.stage_index}-#{task.stage_name}" if %w[run plan-review-run].include?(verb)

        Hive::Workflows.for_verb(verb).fetch(:target)
      rescue KeyError, Hive::Error
        "#{task.stage_index}-#{task.stage_name}"
      end
    end
  end
end
