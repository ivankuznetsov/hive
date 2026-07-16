require "hive/paths"
require "hive/daemon/dispatch_request_queue"

module Hive
  module Bot
    # Writes dispatch request files into the daemon's queue directory.
    # The bot is a producer only; the daemon is the single dispatcher.
    module DispatchRequestWriter
      module_function

      def generate_request_id
        Hive::Daemon::DispatchRequestQueue.generate_request_id
      end

      def write!(project:, slug:, argv:, chat_id: nil, update_id: nil,
                 trigger: nil, request_id: generate_request_id,
                 task_generation: nil, predecessor_attempt_id: nil,
                 inherited_outputs: [],
                 state_home: Hive::Paths.state_home, now: Time.now)
        Hive::Daemon::DispatchRequestQueue.write_request!(
          project: project,
          slug: slug,
          argv: argv,
          requestor: "bot",
          chat_id: chat_id,
          update_id: update_id,
          trigger: trigger,
          request_id: request_id,
          task_generation: task_generation,
          predecessor_attempt_id: predecessor_attempt_id,
          inherited_outputs: inherited_outputs,
          state_home: state_home,
          now: now
        )
      end

      def write_sequence!(request_id:, remaining_argvs:, state_home: Hive::Paths.state_home)
        Hive::Daemon::DispatchRequestQueue.write_sequence!(
          request_id,
          remaining_argvs: remaining_argvs,
          state_home: state_home
        )
      end

      def discard_sequence!(request_id:, state_home: Hive::Paths.state_home)
        Hive::Daemon::DispatchRequestQueue.discard_sequence(
          request_id,
          state_home: state_home
        )
      end
    end
  end
end
