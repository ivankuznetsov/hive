require "securerandom"
require "hive/attempts/capacity_snapshot"
require "hive/attempts/generation"
require "hive/task_resolver"
require "hive/workflows"

module Hive
  module Attempts
    class InvalidSuccessorAuthorization < Hive::Error; end

    # Result of semantic admission. Live duplicates are ordinary successful
    # resolutions, not errors; only a fresh :accepted result invokes launcher.
    DispatchResult = Data.define(:status, :attempt, :receipt, :attach_descriptor, :reason) do
      def accepted? = status == :accepted
      def live? = %i[accepted existing_live].include?(status)
    end

    class Dispatcher
      DEFAULT_LIMITS = { max_global: 3, max_per_project: 3, max_daily: 50 }.freeze

      def initialize(store:, launcher:, limits: DEFAULT_LIMITS, clock: -> { Time.now.utc },
                     id_generator: -> { SecureRandom.uuid }, task_resolver: nil,
                     launch_timeout_sec: 30)
        @store = store
        @launcher = launcher
        @limits = DEFAULT_LIMITS.merge(limits)
        @clock = clock
        @id_generator = id_generator
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

      # RetryCoordinator is the only producer of delayed-retry authorization.
      # The attempt layer validates its fenced fields, then performs the same
      # capacity/claim/launch path as every other durable dispatch.
      def dispatch_authorized_successor(authorization:, predecessor:, task:, project:, argv:,
                                        request_id:, provider:, inherited_outputs: nil,
                                        interactive: false, now: @clock.call, on_claim: nil)
        validate_successor_authorization!(authorization, predecessor)
        generation = Generation.resolve(
          task: task,
          project: project,
          intended_stage: predecessor["intended_stage"],
          progress_token: predecessor["progress_token"],
          ownership_generation: predecessor.ownership_generation,
          task_input_epoch: predecessor.task_input_epoch
        )
        inherited = inherited_outputs ||
                    (predecessor["inherited_outputs"] + predecessor["current_outputs"]).uniq
        admit(
          task: task, generation: generation, argv: argv, request_id: request_id,
          provider: provider, interactive: interactive,
          predecessor_attempt_id: predecessor.attempt_id,
          inherited_outputs: inherited, retry_charge: predecessor["retry_charge"],
          successor_of: predecessor.attempt_id,
          successor_states: %w[terminal lost], on_claim: on_claim, now: now
        )
      end

      # Resolves a daemon request through the normal durable-dispatch task and
      # provider boundary, but requires the RetryCoordinator's fenced token.
      # This keeps delayed redispatch from growing a parallel spawn path.
      def dispatch_authorized_request(authorization:, request:, interactive: false,
                                      now: @clock.call, on_claim: nil)
        task = @task_resolver.call(request)
        predecessor = @store.fetch(authorization.predecessor_attempt_id)
        raise InvalidSuccessorAuthorization, "retry predecessor does not exist" unless predecessor

        dispatch_authorized_successor(
          authorization: authorization, predecessor: predecessor, task: task,
          project: request.project, argv: request.argv, request_id: request.request_id,
          provider: provider_for(task), inherited_outputs: request.inherited_outputs,
          interactive: interactive, now: now, on_claim: on_claim
        )
      end

      def dispatch_request(request, interactive: false, now: @clock.call)
        task = @task_resolver.call(request)
        intended_stage = intended_stage_for(request.argv, task)
        generation = Generation.resolve(
          task: task, project: request.project, intended_stage: intended_stage,
          task_generation: request.respond_to?(:task_generation) ? request.task_generation : nil
        )
        predecessor_id = request.respond_to?(:predecessor_attempt_id) ? request.predecessor_attempt_id : nil
        predecessor = predecessor_id && @store.fetch(predecessor_id)
        if predecessor&.state == "lost"
          return DispatchResult.new(
            status: :deferred, attempt: predecessor, receipt: nil,
            attach_descriptor: nil, reason: "retry_authorization_required"
          )
        end

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
                predecessor_attempt_id:, inherited_outputs:, retry_charge:, successor_of:, now:,
                successor_states: [ "lost" ], on_claim: nil)
        result = nil
        created = nil
        @store.with_generation_lock(generation.task_generation) do
          records = @store.scan.records
          semantic_owner = find_semantic_owner(records, generation)
          if semantic_owner&.live?
            result = live_result(semantic_owner, interactive: interactive)
            next
          end

          exact = records.select { |record| record.task_generation == generation.task_generation }
          terminal = exact.reverse.find { |record| record.state == "terminal" }
          if terminal && successor_of.nil?
            result = DispatchResult.new(
              status: :terminal_replay, attempt: terminal, receipt: terminal.receipt,
              attach_descriptor: nil, reason: nil
            )
            next
          end

          lost = exact.select { |record| record.state == "lost" }
          predecessor = successor_of && exact.find { |record| record.attempt_id == successor_of }
          if successor_of && (!predecessor || !successor_states.include?(predecessor.state))
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
            starting_revision: starting_revision(task),
            retry_charge: retry_charge,
            inherited_outputs: inherited_outputs || [],
            launch_timeout_sec: @launch_timeout_sec,
            now: now
          )
        end

        return result if result

        begin
          on_claim&.call(created)
          @launcher.launch(created, argv: argv)
        rescue StandardError
          begin
            current = @store.fetch(created.attempt_id)
            @store.mark_lost(current, reason: "successor_launch_failed", now: now) if current&.live?
          rescue Hive::Error
            # The original callback/launcher error remains the actionable one;
            # reconciliation will retain the still-live reservation if the
            # defensive loss transition itself raced.
          end
          raise
        end
        DispatchResult.new(
          status: :accepted, attempt: created, receipt: nil,
          attach_descriptor: interactive ? attach_descriptor(created) : nil,
          reason: nil
        )
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

      def validate_successor_authorization!(authorization, predecessor)
        fields = %i[token project task_slug stage generation predecessor_attempt_id]
        unless fields.all? { |field| authorization.respond_to?(field) }
          raise InvalidSuccessorAuthorization, "retry successor requires a typed coordinator authorization"
        end
        unless authorization.token.is_a?(String) && !authorization.token.empty? && predecessor&.final?
          raise InvalidSuccessorAuthorization, "retry successor authorization is incomplete"
        end
        unless authorization.project.to_s == predecessor["project"] &&
               authorization.task_slug.to_s == predecessor["task_slug"] &&
               authorization.stage.to_s == predecessor["intended_stage"] &&
               authorization.generation == predecessor.task_input_epoch &&
               authorization.predecessor_attempt_id.to_s == predecessor.attempt_id &&
               !(predecessor.state == "terminal" && predecessor.outcome == "succeeded")
          raise InvalidSuccessorAuthorization, "retry successor authorization is stale or mismatched"
        end
      end

      def live_result(record, interactive:)
        DispatchResult.new(
          status: :existing_live, attempt: record, receipt: nil,
          attach_descriptor: interactive ? attach_descriptor(record) : nil,
          reason: nil
        )
      end

      def attach_descriptor(record)
        { "attempt_id" => record.attempt_id }
      end

      def normalize_generation(generation, task:, project:, intended_stage:)
        return generation if generation.is_a?(Generation)

        Generation.resolve(
          task: task, project: project, intended_stage: intended_stage,
          task_generation: generation
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
