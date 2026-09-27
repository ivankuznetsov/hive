require "hive/daemon/patrol_scheduler"
require "hive/one_shot/adapter_harness"
require "hive/one_shot/process_executor"
require "hive/one_shot/patrol_admission"
require "hive/one_shot/project_guard"
require "hive/one_shot/project_liveness"
require "hive/one_shot/result"

module Hive
  module OneShot
    class PatrolAdapter
      def initialize(entry:, dry_run: false, scheduler: nil, executor: nil,
                     guard: nil, liveness: nil, controller: nil,
                     clock: -> { Time.now.utc })
        @entry = entry
        @dry_run = dry_run
        @clock = clock
        @executor = executor || ProcessExecutor.for_entry(entry)
        @guard = guard || ProjectGuard.new(
          state_root: entry.fetch("hive_state_path"), project: entry.fetch("name"),
          kind: :one_shot
        )
        @liveness = liveness || ProjectLiveness.new(entry: entry)
        @admission = PatrolAdmission.new(entry: entry, controller: controller)
        @scheduler = scheduler || Hive::Daemon::PatrolScheduler.new(
          registry: -> { [ entry ] }
        )
      end

      def call
        ran = []
        AdapterHarness.call(
          component: :patrol, project: project, clock: @clock, ran: -> { ran },
          error_code: method(:error_code)
        ) do |started|
          @guard.synchronize do
            gate = @admission.gate(now: started)
            unless @dry_run
              candidate = @scheduler.candidates(
                now: started, projects: [ project ],
                bypass_observation_throttle: true, strict: true
              ).first
              run_candidate(candidate, ran) if candidate && gate == :ok
            end
            finished = @clock.call
            items = @scheduler.readiness(project: project, now: finished, persist: !@dry_run)
            items = @admission.apply(items, gate: gate, now: finished)
            Result.ok(
              component: :patrol, project: project, started_at: started,
              finished_at: finished, ran: ran, items: items,
              safe_to_stop: @liveness.safe_to_stop?
            )
          end
        end
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
      rescue StandardError, Interrupt, SignalException
        @scheduler.complete(project: project, exit_code: 1, now: @clock.call) if reserved
        raise
      end

      def error_code(error)
        error.respond_to?(:code) ? error.code : error.class.name.split("::").last
          .gsub(/([a-z])([A-Z])/, '\\1_\\2').downcase
      end
    end
  end
end
