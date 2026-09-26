require "hive/one_shot/project_guard"
require "hive/one_shot/result"

module Hive
  module OneShot
    module AdapterHarness
      module_function

      def call(component:, project:, clock:, ran:, error_code: "observation_failed")
        started = clock.call
        yield(started)
      rescue ProjectGuard::OwnershipError => error
        Result.refused(
          component: component, project: project, started_at: started,
          finished_at: clock.call, code: error.code, message: error.message,
          owner: error.owner
        )
      rescue Interrupt, SignalException => error
        Result.interrupted(
          component: component, project: project, started_at: started,
          finished_at: clock.call, message: error.message, ran: ran.call
        )
      rescue StandardError => error
        fallback = error_code.respond_to?(:call) ? error_code.call(error) : error_code
        Result.error(
          component: component, project: project, started_at: started,
          finished_at: clock.call,
          code: error.respond_to?(:code) ? error.code : fallback,
          message: error.message, ran: ran.call,
          exit_code: error.respond_to?(:exit_code) ? error.exit_code : Hive::ExitCodes::TEMPFAIL
        )
      end
    end
  end
end
