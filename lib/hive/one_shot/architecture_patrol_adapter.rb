require "hive/config"
require "hive/daemon/refactor_patrol_merge_reconciler"
require "hive/daemon/refactor_patrol_scheduler"
require "hive/lock"
require "hive/one_shot/process_executor"
require "hive/one_shot/project_guard"
require "hive/one_shot/result"
require "hive/one_shot/schedule_state"

module Hive
  module OneShot
    class ArchitecturePatrolAdapter
      def initialize(entry:, dry_run: false, scheduler: nil, reconciler: nil,
                     executor: ProcessExecutor.new, guard: nil,
                     config_loader: ->(path) { Hive::Config.load(path) },
                     clock: -> { Time.now.utc })
        @entry = entry
        @dry_run = dry_run
        @clock = clock
        @executor = executor
        @config_loader = config_loader
        registry = -> { [ entry ] }
        @guard = guard || ProjectGuard.new(
          state_root: entry.fetch("hive_state_path"), project: entry.fetch("name"),
          kind: :one_shot
        )
        @scheduler = scheduler || Hive::Daemon::RefactorPatrolScheduler.new(
          registry: registry, dry_run: dry_run
        )
        @reconciler = reconciler || Hive::Daemon::RefactorPatrolMergeReconciler.new(
          registry: registry, dry_run: dry_run
        )
        @schedule_state = ScheduleState.new(state_root: entry.fetch("hive_state_path"))
      end

      def call
        started = @clock.call
        ran = []
        @guard.synchronize do
          intake = run_intake(started, ran)
          return observation_error(started, ran, intake) if intake_error?(intake)

          candidates = @scheduler.candidates(
            now: @clock.call, projects: [ project ], include_scheduled: false
          )
          run_candidate(candidates.first, ran) if candidates.first && !@dry_run
          finished = @clock.call
          items = @scheduler.readiness(project: project, now: finished)
          items.concat(intake_items(intake, finished)) if enabled?
          items.concat(event_items(@scheduler.drain_events))
          return Result.ok(
            component: :architecture_patrol, project: project,
            started_at: started, finished_at: finished, ran: ran,
            items: items, safe_to_stop: true
          )
        end
      rescue ProjectGuard::OwnershipError => error
        Result.refused(
          component: :architecture_patrol, project: project,
          started_at: started, finished_at: @clock.call, code: error.code,
          message: error.message, owner: error.owner
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
        persist_intake_deadline(now) unless @dry_run || !enabled?
        result
      end

      def persist_intake_deadline(now)
        @schedule_state.update("architecture_patrol", now: now) do |state|
          state.merge(
            "intake_next_check_at" =>
              (now + Hive::Daemon::RefactorPatrolMergeReconciler::DEFAULT_POLL_INTERVAL_SEC)
                .utc.iso8601(6)
          )
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
          return [ item("waiting_external", "intake", "backoff", result[:retry_at]) ]
        end

        deadline = now + Hive::Daemon::RefactorPatrolMergeReconciler::DEFAULT_POLL_INTERVAL_SEC
        [ item("waiting_external", "intake", "recurring_intake", deadline) ]
      end

      def event_items(events)
        Array(events).map do |event|
          item(
            "waiting_operator", "event:#{event[:job_id] || event[:occurrence_id] || event[:reason]}",
            event[:reason] || event[:status].to_s, nil, "operator_action"
          )
        end
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
