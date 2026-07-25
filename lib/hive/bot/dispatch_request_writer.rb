require "time"
require "hive/paths"
require "hive/daemon/dispatch_request_queue"
require "hive/daemon/recovery_coordinator"
require "hive/attempts/api"
require "hive/task"
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
      RecoveryObservation = Data.define(
        :project, :slug, :folder, :state_file, :stage, :workflow, :marker,
        :marker_attrs, :state_file_mtime, :live_task_lock, :attempt_id,
        :task_generation, :suggested_command
      )

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
                    entrypoint: nil)
        write!(
          project: project, slug: slug, argv: argv,
          chat_id: chat_id, update_id: update_id, trigger: trigger,
          request_id: request_id, state_home: state_home, now: now
        )

        task = resolve_task(project: project, slug: slug, argv: argv)
        intended_stage = intended_stage_for(argv, task)
        result = (entrypoint || Hive::Attempts::API.new).dispatch(
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

      # All ERROR / REVIEW_ERROR callers cross this boundary. Surface-specific
      # rows are normalized once, then the coordinator owns cooldown, lock,
      # safety, marker generation, durable admission, and lifecycle truth.
      def recover!(row:, project: nil, requestor: "bot", chat_id: nil,
                   update_id: nil, request_id: nil, observation_token: nil,
                   state_home: Hive::Paths.state_home, now: Time.now,
                   coordinator: nil)
        observation = recovery_observation(row, project: project)
        coordinator ||= Hive::Daemon::RecoveryCoordinator.new(state_home: state_home)
        observation_token ||= coordinator.observation_token_for(observation)
        coordinator.request(
          row: observation,
          requestor: requestor,
          request_id: request_id,
          observation_token: observation_token,
          chat_id: chat_id,
          update_id: update_id,
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

      def recovery_observation(row, project: nil)
        folder = row_value(row, :folder)
        state_file = row_value(row, :state_file)
        if state_file.to_s.empty? && !folder.to_s.empty?
          state_file = Hive::Task.new(folder.to_s).state_file
        end
        RecoveryObservation.new(
          project: project || row_value(row, :project) || row_value(row, :project_name),
          slug: row_value(row, :slug),
          folder: folder,
          state_file: state_file,
          stage: row_value(row, :stage),
          workflow: row_value(row, :workflow),
          marker: row_value(row, :marker),
          marker_attrs: normalized_marker_attrs(row),
          state_file_mtime: observed_mtime(row, state_file),
          live_task_lock: row_value(row, :live_task_lock) == true,
          attempt_id: row_value(row, :attempt_id) || row_value(row, :current_attempt),
          task_generation: row_value(row, :task_generation) ||
            row_value(row, :condition_task_generation),
          suggested_command: row_value(row, :suggested_command)
        )
      end

      def row_value(row, key)
        return row.public_send(key) if row.respond_to?(key)
        return row[key] if row.respond_to?(:key?) && row.key?(key)
        return row[key.to_s] if row.respond_to?(:key?) && row.key?(key.to_s)
        return row[key.to_s] if row.respond_to?(:[])

        nil
      end

      def normalized_marker_attrs(row)
        attrs = row_value(row, :marker_attrs)
        attrs = row_value(row, :attrs) unless attrs.is_a?(Hash)
        attrs.is_a?(Hash) ? attrs.to_h.transform_keys(&:to_s) : {}
      end

      def observed_mtime(row, state_file)
        observed = row_value(row, :state_file_mtime) || row_value(row, :mtime)
        return observed.utc if observed.respond_to?(:utc)
        return Time.iso8601(observed.to_s).utc unless observed.to_s.empty?
        return File.mtime(state_file).utc if state_file && File.exist?(state_file)

        nil
      rescue ArgumentError, SystemCallError
        nil
      end
    end
  end
end
