require "set"
require "hive/babysitter/interval"
require "hive/babysitter/project_tick"
require "hive/config"
require "hive/one_shot/adapter_harness"
require "hive/one_shot/project_guard"
require "hive/one_shot/project_liveness"
require "hive/one_shot/result"
require "hive/one_shot/schedule_state"

module Hive
  module OneShot
    class BabysitterAdapter
      class NullLogger
        def event(*) = nil
      end

      def initialize(entry:, dry_run: false, logger: NullLogger.new,
                     config_loader: ->(path) { Hive::Config.load(path) },
                     tick: Hive::Babysitter::ProjectTick, main_guard: nil,
                     babysitter_guard: nil, liveness: nil,
                     clock: -> { Time.now.utc })
        @entry = entry
        @dry_run = dry_run
        @logger = logger
        @config_loader = config_loader
        @tick = tick
        @clock = clock
        @main_guard = main_guard || guard(:one_shot, ProjectGuard::LOCK_NAME)
        @babysitter_guard = babysitter_guard || guard(
          :babysitter, Hive::Babysitter::ProjectTick::EXECUTION_LOCK_NAME
        )
        @liveness = liveness || ProjectLiveness.new(entry: entry)
        @schedule_state = ScheduleState.new(state_root: entry.fetch("hive_state_path"))
      end

      def call
        summary = nil
        effective_dry_run = @dry_run
        ran = -> { summary ? ran_items(summary, dry_run: effective_dry_run) : [] }
        AdapterHarness.call(
          component: :babysitter, project: project, clock: @clock, ran: ran
        ) do |started|
          @main_guard.synchronize do
            @babysitter_guard.synchronize do
              cfg = @config_loader.call(@entry.fetch("path"))
              unless eligible?(cfg)
                return Result.ok(
                  component: :babysitter, project: project, started_at: started,
                  finished_at: @clock.call, ran: [], items: [],
                  safe_to_stop: @liveness.safe_to_stop?
                )
              end
              @schedule_state.read("babysitter")
              effective_dry_run ||= cfg.dig("babysitter", "dry_run") == true
              summary = @tick.run(
                @entry, dry_run: effective_dry_run, logger: @logger, inflight: Set.new,
                observe_only: effective_dry_run, detailed: true
              )
              return failed_result(started, summary, dry_run: effective_dry_run) if summary[:error]

              finished = @clock.call
              deadline = finished + Hive::Babysitter::Interval.parse(cfg.dig("babysitter", "interval"))
              persist_deadline(deadline, finished) unless effective_dry_run
              Result.ok(
                component: :babysitter, project: project, started_at: started,
                finished_at: finished, ran: ran.call,
                items: pending_items(summary, deadline),
                safe_to_stop: summary[:interrupted] != true && @liveness.safe_to_stop?
              )
            end
          end
        end
      end

      private

      def project = @entry.fetch("name")

      def guard(kind, lock_name)
        ProjectGuard.new(
          state_root: @entry.fetch("hive_state_path"), project: project,
          kind: kind, lock_name: lock_name
        )
      end

      def eligible?(cfg)
        identity = @entry["repository_identity"].to_s
        cfg.dig("babysitter", "enabled") == true && !identity.empty? &&
          !identity.start_with?("local:")
      end

      def persist_deadline(deadline, now)
        @schedule_state.update("babysitter", now: now) do |state|
          state.merge("next_check_at" => deadline.utc.iso8601(6))
        end
      end

      def failed_result(started, summary, dry_run:)
        error = summary.fetch(:error)
        Result.error(
          component: :babysitter, project: project, started_at: started,
          finished_at: @clock.call, code: error.fetch(:code),
          message: error.fetch(:message), ran: ran_items(summary, dry_run: dry_run)
        )
      end

      def ran_items(summary, dry_run:)
        return [] if dry_run

        Array(summary[:prs]).filter_map do |pr|
          outcome = pr.fetch(:outcome).to_sym
          next if %i[runnable pipeline_owned inflight].include?(
            Hive::Babysitter::ProjectTick.outcome_class(outcome)
          )

          { "id" => "babysitter:pr:#{pr.fetch(:number)}", "action" => "inspect_or_repair",
            "outcome" => outcome.to_s }
        end
      end

      def pending_items(summary, deadline)
        items = Array(summary[:prs]).map { |pr| pr_item(pr, deadline) }
        items << {
          "bucket" => "waiting_external", "id" => "babysitter:poll",
          "component" => "babysitter", "reason" => "recurring_poll",
          "next_check_at" => deadline,
          "condition" => {
            "kind" => "time_due", "project" => project,
            "deadline" => deadline.utc.iso8601(6)
          }
        }
        items
      end

      def pr_item(pr, deadline)
        outcome = pr.fetch(:outcome).to_sym
        projections = {
          runnable: [ "runnable_now", nil, nil ],
          operator: [ "waiting_operator", nil, "operator_action" ],
          retry: [ "waiting_external", deadline, "time_due" ],
          pipeline_owned: [ "waiting_external", nil, "task_changed" ],
          inflight: [ "waiting_external", nil, "attempt_completed" ],
          observed: [
            "waiting_external", nil,
            pr[:wait] == "checks_pending" ? "check_state_changed" : "pr_changed"
          ]
        }
        bucket, due, kind = projections.fetch(
          Hive::Babysitter::ProjectTick.outcome_class(outcome)
        )
        condition = kind && {
          "kind" => kind, "repository" => @entry.fetch("repository_identity"),
          "pr" => pr.fetch(:number)
        }
        condition["deadline"] = due.utc.iso8601(6) if due
        condition["head_sha"] = pr[:head_sha] if condition && pr[:head_sha]
        {
          "bucket" => bucket,
          "id" => "babysitter:pr:#{pr.fetch(:number)}", "component" => "babysitter",
          "reason" => outcome.to_s, "next_check_at" => due, "condition" => condition
        }
      end
    end
  end
end
