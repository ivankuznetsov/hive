require "hive/daemon/patrol_scheduler"
require "hive/one_shot/process_executor"
require "hive/one_shot/project_guard"
require "hive/one_shot/result"

module Hive
  module OneShot
    class PatrolAdapter
      def initialize(entry:, dry_run: false, scheduler: nil, executor: ProcessExecutor.new,
                     guard: nil, clock: -> { Time.now.utc })
        @entry = entry
        @dry_run = dry_run
        @clock = clock
        @executor = executor
        @guard = guard || ProjectGuard.new(
          state_root: entry.fetch("hive_state_path"), project: entry.fetch("name"),
          kind: :one_shot
        )
        @scheduler = scheduler || Hive::Daemon::PatrolScheduler.new(
          registry: -> { [ entry ] }
        )
      end

      def call
        started = @clock.call
        ran = []
        @guard.synchronize do
          unless @dry_run
            candidate = @scheduler.candidates(
              now: started, projects: [ project ],
              bypass_observation_throttle: true, strict: true
            ).first
            run_candidate(candidate, ran) if candidate
          end
          finished = @clock.call
          items = @scheduler.readiness(project: project, now: finished, persist: !@dry_run)
          return Result.ok(
            component: :patrol, project: project, started_at: started,
            finished_at: finished, ran: ran, items: items, safe_to_stop: true
          )
        end
      rescue ProjectGuard::OwnershipError => error
        Result.refused(
          component: :patrol, project: project, started_at: started,
          finished_at: @clock.call, code: error.code, message: error.message,
          owner: error.owner
        )
      rescue StandardError => error
        Result.error(
          component: :patrol, project: project, started_at: started,
          finished_at: @clock.call, code: error_code(error),
          message: error.message, ran: ran, exit_code: hive_exit_code(error)
        )
      end

      private

      def project = @entry.fetch("name")

      def run_candidate(candidate, ran)
        reserved = @scheduler.reserve(candidate, now: @clock.call)
        return unless reserved

        execution = @executor.call(reserved.fetch(:command))
        @scheduler.complete(
          project: project, exit_code: execution.exit_code,
          envelope: execution.envelope, now: @clock.call
        )
        ran << {
          "id" => "patrol:scan", "action" => "scan",
          "outcome" => execution.exit_code.zero? ? "completed" : "failed"
        }
      rescue StandardError
        @scheduler.complete(project: project, exit_code: 1, now: @clock.call) if reserved
        raise
      end

      def error_code(error)
        error.respond_to?(:code) ? error.code : error.class.name.split("::").last
          .gsub(/([a-z])([A-Z])/, '\\1_\\2').downcase
      end

      def hive_exit_code(error)
        error.respond_to?(:exit_code) ? error.exit_code : Hive::ExitCodes::TEMPFAIL
      end
    end
  end
end
