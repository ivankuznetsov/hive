require "hive/one_shot/adapter_harness"
require "hive/one_shot/runner"

module Hive
  module OneShot
    class DispatchAdapter
      def initialize(entry:, hive_home: Hive::Paths.state_home, dry_run: false,
                     guard: nil, runner_factory: nil, clock: -> { Time.now.utc })
        @entry = entry
        @dry_run = dry_run
        @clock = clock
        @guard = guard || ProjectGuard.new(
          state_root: entry.fetch("hive_state_path"), project: entry.fetch("name"),
          kind: :one_shot
        )
        @runner_factory = runner_factory || lambda do
          Runner.build(entry: entry, hive_home: hive_home, dry_run: dry_run, clock: clock)
        end
      end

      def call
        runner = nil
        AdapterHarness.call(
          component: :dispatch, project: project, clock: @clock,
          ran: -> { runner&.ran || [] }, error_code: "dispatch_failed"
        ) do |started|
          @guard.synchronize do
            runner = @runner_factory.call
            pass = runner.call
            Result.ok(
              component: :dispatch, project: project, started_at: started,
              finished_at: @clock.call, ran: pass.fetch(:ran), items: pass.fetch(:items),
              safe_to_stop: pass.fetch(:safe_to_stop)
            )
          ensure
            runner&.close
          end
        end
      end

      private

      def project = @entry.fetch("name")
    end
  end
end
