require "securerandom"
require "hive/attempts/contracts"
require "hive/attempts/capability"
require "hive/attempts/capacity_snapshot"
require "hive/attempts/generation"
require "hive/task_resolver"
require "hive/workflows"

module Hive
  module Attempts
    class Dispatcher
      DEFAULT_LIMITS = { max_global: 3, max_per_project: 3, max_daily: 50 }.freeze

      def initialize(store:, launcher:, limits: DEFAULT_LIMITS, clock: -> { Time.now.utc },
                     id_generator: -> { SecureRandom.uuid }, task_resolver: nil,
                     capability_generator: Capability.method(:generate),
                     launch_timeout_sec: 30)
        @store = store
        @launcher = launcher
        @limits = DEFAULT_LIMITS.merge(limits)
        @clock = clock
        @id_generator = id_generator
        @capability_generator = capability_generator
        @task_resolver = task_resolver || method(:resolve_request_task)
        @launch_timeout_sec = launch_timeout_sec
      end

      def dispatch(task:, project:, intended_stage:, argv:, request_id:, provider:,
                   interactive: false, generation: nil, predecessor_attempt_id: nil,
                   inherited_outputs: [], retry_charge: 0, now: @clock.call)
        @launcher.preflight!
        generation = normalize_generation(
          generation, task: task, project: project, intended_stage: intended_stage
        )
        admit(
          task: task, generation: generation, argv: argv, request_id: request_id,
          provider: provider, interactive: interactive,
          predecessor_attempt_id: predecessor_attempt_id,
          inherited_outputs: inherited_outputs, retry_charge: retry_charge,
          successor_of: nil, now: now
        )
      end

      def dispatch_successor(predecessor:, task:, project:, argv:, request_id:, provider:,
                             inherited_outputs: nil, retry_charge: nil, interactive: false,
                             now: @clock.call)
        @launcher.preflight!
        generation = Generation.resolve(
          task: task,
          project: project,
          intended_stage: predecessor["intended_stage"],
          progress_token: predecessor["progress_token"],
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
          successor_of: predecessor.attempt_id, now: now
        )
      end

      def dispatch_request(request, interactive: false, now: @clock.call)
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
          inherited_outputs: request.inherited_outputs, interactive: interactive, now: now
        ) if predecessor&.state == "lost"

        dispatch(
          task: task, project: request.project, intended_stage: intended_stage,
          argv: request.argv, request_id: request.request_id, provider: provider_for(task),
          interactive: interactive, generation: generation,
          inherited_outputs: request.respond_to?(:inherited_outputs) ? request.inherited_outputs : [],
          now: now
        )
      end

      private

      def admit(task:, generation:, argv:, request_id:, provider:, interactive:,
                predecessor_attempt_id:, inherited_outputs:, retry_charge:, successor_of:, now:)
        result = nil
        created = nil
        claim_capability = nil
        # Fixed lock order: global admission, then task generation. The outer
        # lock makes the capacity snapshot and reservation one host-wide
        # transaction even when concurrent requests have different generations.
        @store.with_admission_lock do
          @store.with_generation_lock(generation.task_generation) do
            records = @store.scan.records
            semantic_owner = find_semantic_owner(records, generation)
            if semantic_owner&.live?
              result = live_result(semantic_owner, interactive: interactive)
              next
            end

            exact = records.select { |record| record.task_generation == generation.task_generation }
            terminal = replayable_terminal(exact, request_id)
            if terminal
              result = DispatchResult.new(
                status: :terminal_replay, attempt: terminal, receipt: terminal.receipt,
                attach_descriptor: nil, reason: nil
              )
              next
            end

            lost = unresolved_lost_attempts(exact)
            predecessor = successor_of && exact.find { |record| record.attempt_id == successor_of }
            if successor_of && (!predecessor || predecessor.state != "lost")
              result = DispatchResult.new(
                status: :deferred, attempt: predecessor, receipt: nil,
                attach_descriptor: nil, reason: "invalid_predecessor"
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

            snapshot = CapacitySnapshot.build(store: @store, now: now)
            if snapshot.at_limit?(
              project: generation.project, task_slug: generation.task_slug, date: now.to_date,
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

            claim_capability = @capability_generator.call
            created = @store.create_launching(
              attempt_id: @id_generator.call,
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
              provider: provider.to_s,
              worker_argv: argv,
              claim_capability_digest: Capability.digest(claim_capability),
              starting_revision: starting_revision(task),
              retry_charge: retry_charge,
              inherited_outputs: inherited_outputs || [],
              launch_timeout_sec: @launch_timeout_sec,
              now: now
            )
          end
        end

        return result if result

        handoff = @launcher.launch(created, claim_capability: claim_capability)
        if handoff.is_a?(Hash) && (handoff["claimed"] == true || handoff["state"] == "launching")
          return accepted_result(created, interactive: interactive)
        end

        resolve_failed_handoff(
          created, interactive: interactive, error: handoff.is_a?(Hash) ? handoff["error"] : nil
        )
      rescue StandardError => e
        raise unless created

        resolve_failed_handoff(created, interactive: interactive, error: "#{e.class}: #{e.message}")
      end

      # Request IDs own delivery idempotency: replaying the same request must
      # keep returning its original receipt, including a failure. A different
      # request is a deliberate retry, so only a successful terminal receipt
      # remains the semantic owner of the unchanged generation.
      def replayable_terminal(records, request_id)
        terminals = records.select { |record| record.state == "terminal" }
        terminals.reverse.find { |record| record["request_id"] == request_id } ||
          terminals.reverse.find { |record| record.outcome == "succeeded" }
      end

      # A lost attempt blocks ordinary admission only until its explicit
      # successor exists. Once that descendant terminalizes unsuccessfully, a
      # new error-retry request must not be trapped behind the older resolved
      # loss forever.
      def unresolved_lost_attempts(records)
        resolved = records.filter_map { |record| record["predecessor_attempt_id"] }.to_h do |attempt_id|
          [ attempt_id, true ]
        end
        records.select { |record| record.state == "lost" && !resolved[record.attempt_id] }
      end

      def find_semantic_owner(records, generation)
        candidates = records.select do |record|
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

      def accepted_result(record, interactive:)
        DispatchResult.new(
          status: :accepted, attempt: record, receipt: nil,
          attach_descriptor: interactive ? attach_descriptor(record) : nil,
          reason: nil
        )
      end

      def resolve_failed_handoff(created, interactive:, error: nil)
        current = @store.fetch(created.attempt_id)
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
        deferred_handoff_result(lost)
      rescue CompareAndSwapFailed
        current = @store.fetch(created.attempt_id)
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
