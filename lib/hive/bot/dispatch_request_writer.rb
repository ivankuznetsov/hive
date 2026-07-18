require "hive/paths"
require "hive/daemon/dispatch_request_queue"
require "hive/attempts/entrypoint"
require "hive/task_resolver"
require "hive/workflows"

module Hive
  module Bot
    # Writes dispatch request files into the daemon's queue directory.
    # The bot is a producer only; the daemon is the single dispatcher.
    module DispatchRequestWriter
      module_function

      DispatchReference = Data.define(:request_id, :attempt_id, :state, :status, :argv) do
        def queued? = status == :queued
      end

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

      # Durable foreground delivery. The queue file is written first and
      # remains the delivery record even when this process admits the attempt
      # immediately; a daemon can later correlate its receipt after restart.
      # Capacity/unavailable-local cases simply leave the request pending.
      def dispatch!(project:, slug:, argv:, chat_id: nil, update_id: nil,
                    trigger: nil, request_id: generate_request_id,
                    state_home: Hive::Paths.state_home, now: Time.now,
                    entrypoint: Hive::Attempts::Entrypoint.new)
        write!(
          project: project, slug: slug, argv: argv,
          chat_id: chat_id, update_id: update_id, trigger: trigger,
          request_id: request_id, state_home: state_home, now: now
        )

        task = resolve_task(project: project, slug: slug, argv: argv)
        intended_stage = intended_stage_for(argv, task)
        result = entrypoint.dispatch(
          task: task,
          intended_stage: intended_stage,
          argv: argv,
          request_id: request_id,
          interactive: false,
          now: now.utc
        )
        Hive::Daemon::DispatchRequestQueue.claim(
          request_id,
          pid: nil,
          process_start_time: nil,
          attempt_id: result.attempt.attempt_id,
          task_generation: result.attempt.task_generation,
          now: now,
          state_home: state_home
        )
        DispatchReference.new(
          request_id: request_id.to_s,
          attempt_id: result.attempt.attempt_id,
          state: result.attempt.state,
          status: result.status,
          argv: argv
        )
      rescue Hive::ConcurrentRunError, Hive::Attempts::UnsupportedDetachment,
             Hive::InvalidTaskPath, Hive::ConfigError
        DispatchReference.new(
          request_id: request_id.to_s, attempt_id: nil, state: "queued",
          status: :queued, argv: argv
        )
      rescue StandardError
        Hive::Daemon::DispatchRequestQueue.remove_if_unclaimed(
          request_id, state_home: state_home
        )
        raise
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

      def resolve_task(project:, slug:, argv:)
        Hive::TaskResolver.new(
          slug,
          project_filter: project,
          stage_filter: stage_filter_for(argv)
        ).resolve
      end

      def stage_filter_for(argv)
        tokens = Array(argv)
        index = tokens.index { |token| %w[--stage --from].include?(token) }
        index ? tokens[index + 1] : nil
      end

      def intended_stage_for(argv, task)
        verb = Array(argv)[1].to_s
        return "#{task.stage_index}-#{task.stage_name}" if verb == "run"

        Hive::Workflows.for_verb(verb).fetch(:target)
      end
    end
  end
end
