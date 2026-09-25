require "hive/config"
require "digest"
require "json"
require "hive/daemon/refactor_patrol_merge_reconciler"
require "hive/daemon/refactor_patrol_scheduler"
require "hive/lock"
require "hive/one_shot/process_executor"
require "hive/one_shot/patrol_admission"
require "hive/one_shot/project_guard"
require "hive/one_shot/project_liveness"
require "hive/one_shot/result"
require "hive/one_shot/schedule_state"

module Hive
  module OneShot
    class ArchitecturePatrolAdapter
      def initialize(entry:, dry_run: false, scheduler: nil, reconciler: nil,
                     executor: nil, guard: nil,
                     config_loader: ->(path) { Hive::Config.load(path) },
                     poll_interval_sec: nil, liveness: nil, controller: nil,
                     clock: -> { Time.now.utc })
        @entry = entry
        @dry_run = dry_run
        @clock = clock
        @config_loader = config_loader
        @executor = executor || ProcessExecutor.for_entry(
          entry, config_loader: @config_loader
        )
        @poll_interval_sec = Integer(
          poll_interval_sec || Hive::Config.load_global_daemon.fetch("pr_merge_poll_interval_sec")
        )
        registry = -> { [ entry ] }
        @guard = guard || ProjectGuard.new(
          state_root: entry.fetch("hive_state_path"), project: entry.fetch("name"),
          kind: :one_shot
        )
        @liveness = liveness || ProjectLiveness.new(entry: entry)
        @admission = PatrolAdmission.new(entry: entry, controller: controller)
        @scheduler = scheduler || Hive::Daemon::RefactorPatrolScheduler.new(
          registry: registry, dry_run: dry_run
        )
        @reconciler = reconciler || Hive::Daemon::RefactorPatrolMergeReconciler.new(
          registry: registry, dry_run: dry_run, poll_interval_sec: @poll_interval_sec
        )
        @schedule_state = ScheduleState.new(state_root: entry.fetch("hive_state_path"))
      end

      def call
        started = @clock.call
        ran = []
        @guard.synchronize do
          gate = @admission.gate(now: started)
          intake = run_intake(started, ran)
          return observation_error(started, ran, intake) if intake_error?(intake)

          candidates = @scheduler.candidates(
            now: @clock.call, projects: [ project ], include_scheduled: false
          )
          run_candidate(candidates.first, ran) if candidates.first && !@dry_run && gate == :ok
          finished = @clock.call
          items = @scheduler.readiness(project: project, now: finished)
          items.concat(intake_items(intake, finished)) if enabled?
          events = @scheduler.drain_events
          return event_observation_error(started, ran, events) if observation_failure?(events)

          items.concat(event_items(events))
          items = @admission.apply(items, gate: gate, now: finished)
          persist_intake_deadline(intake_deadline(intake, finished), finished) unless
            @dry_run || !enabled?
          return Result.ok(
            component: :architecture_patrol, project: project,
            started_at: started, finished_at: finished, ran: ran,
            items: items, safe_to_stop: @liveness.safe_to_stop?
          )
        end
      rescue ProjectGuard::OwnershipError => error
        Result.refused(
          component: :architecture_patrol, project: project,
          started_at: started, finished_at: @clock.call, code: error.code,
          message: error.message, owner: error.owner
        )
      rescue Interrupt, SignalException => error
        Result.interrupted(
          component: :architecture_patrol, project: project,
          started_at: started, finished_at: @clock.call, ran: ran,
          message: error.message
        )
      rescue StandardError => error
        Result.error(
          component: :architecture_patrol, project: project,
          started_at: started, finished_at: @clock.call,
          code: error.respond_to?(:code) ? error.code : "observation_failed",
          message: error.message, ran: ran,
          exit_code: error.respond_to?(:exit_code) ? error.exit_code : Hive::ExitCodes::TEMPFAIL
        )
      end

      private

      def project = @entry.fetch("name")

      def enabled?
        cfg = @config_loader.call(@entry.fetch("path"))
        cfg.dig("daemon", "enabled") == true &&
          cfg.dig("refactor_patrol", "enabled") == true &&
          Hive::Workflows.coding_id?(cfg["default_workflow"])
      end

      def run_intake(now, ran)
        results = @reconciler.tick(now: now, projects: [ project ])
        result = results.find { |item| item[:project].to_s == project.to_s }
        if result && Array(result[:enqueued_prs]).any?
          ran << {
            "id" => "architecture:intake", "action" => "merge_intake",
            "outcome" => "completed",
            "details" => { "enqueued_prs" => Array(result[:enqueued_prs]) }
          }
        end
        result
      end

      def persist_intake_deadline(deadline, now)
        @schedule_state.update("architecture_patrol", now: now) do |state|
          state.merge("intake_next_check_at" => deadline.utc.iso8601(6))
        end
      end

      def intake_error?(result) = result && result[:status] == :blocked

      def observation_error(started, ran, result)
        Result.error(
          component: :architecture_patrol, project: project,
          started_at: started, finished_at: @clock.call,
          code: "observation_failed", message: result[:reason] || "architecture intake failed",
          details: result[:error] && { "error" => result[:error] }, ran: ran
        )
      end

      def observation_failure?(events)
        Array(events).any? { |event| event[:status].to_s == "blocked" }
      end

      def event_observation_error(started, ran, events)
        failures = Array(events).select { |event| event[:status].to_s == "blocked" }
        Result.error(
          component: :architecture_patrol, project: project,
          started_at: started, finished_at: @clock.call,
          code: "observation_failed",
          message: failures.map { |event| event[:reason] || "scheduler event blocked" }.uniq.join(", "),
          details: { "events" => failures.map { |event| stringify_keys(event) } },
          ran: ran
        )
      end

      def run_candidate(candidate, ran)
        reserved = @scheduler.reserve(candidate, now: @clock.call)
        return unless reserved

        execution = @executor.call(
          reserved.fetch(:command),
          on_spawn: lambda do |pid|
            identity = Hive::Lock.process_start_time(pid)
            @scheduler.spawned(
              reserved, pid: pid, process_start_time: identity,
              pgid: Process.getpgid(pid), now: @clock.call
            ) if identity
          end
        )
        completion = @scheduler.complete(
          dispatch_token: reserved.fetch(:dispatch_token),
          exit_code: execution.exit_code, envelope: execution.envelope,
          now: @clock.call
        )
        ran << {
          "id" => "architecture:#{candidate.fetch(:job_id)}",
          "action" => candidate.fetch(:action_phase).to_s,
          "outcome" => completion.fetch(:status).to_s
        }
      rescue StandardError
        @scheduler.cancel(reserved, reason: "one_shot_error", now: @clock.call) if reserved
        raise
      end

      def intake_items(result, now)
        if result && %i[partial deferred].include?(result[:status])
          return [ item("runnable_now", "intake", result[:status].to_s) ]
        end
        if result && result[:status] == :backoff
          return [ item("waiting_external", "intake", "backoff", intake_deadline(result, now)) ]
        end

        deadline = intake_deadline(result, now)
        [ item("waiting_external", "intake", "recurring_intake", deadline) ]
      end

      def intake_deadline(result, now)
        return now if result && %i[partial deferred].include?(result[:status])
        return result.fetch(:retry_at) if result && result[:status] == :backoff

        now + @poll_interval_sec
      end

      def event_items(events)
        Array(events).each_with_object({}) do |event, items|
          canonical = JSON.generate(stringify_keys(event).sort.to_h)
          identity = event[:job_id] || event[:occurrence_id] || event[:batch_id] || "anonymous"
          fingerprint = Digest::SHA256.hexdigest(canonical)[0, 16]
          id = "event:#{identity}:#{fingerprint}"
          items[id] ||= item(
            "waiting_operator", id,
            event[:reason] || event[:status].to_s, nil, "operator_action"
          )
        end
          .values
      end

      def stringify_keys(value)
        value.to_h { |key, child| [ key.to_s, child ] }
      end

      def item(bucket, suffix, reason, deadline = nil, kind = "time_due")
        condition = if bucket == "runnable_now"
          nil
        else
          { "kind" => kind, "project" => project }.tap do |value|
            value["deadline"] = deadline.utc.iso8601(6) if deadline.respond_to?(:utc)
            value["deadline"] = deadline if deadline.is_a?(String)
          end
        end
        {
          "bucket" => bucket,
          "id" => "architecture:#{suffix}", "component" => "architecture_patrol",
          "reason" => reason, "next_check_at" => deadline,
          "condition" => condition
        }
      end
    end
  end
end
