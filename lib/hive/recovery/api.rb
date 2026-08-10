require "time"
require "hive/paths"
require "hive/recovery"
require "hive/daemon/recovery_coordinator"
require "hive/task"

module Hive
  module Recovery
    # Neutral adapter shared by CLI, TUI, Rails, recorder, and bot surfaces.
    # It normalizes each surface's row shape once; RecoveryCoordinator remains
    # the sole owner of cooldown, safety, marker mutation, and durable state.
    module API
      module_function

      RECOVERABLE_MARKERS = Hive::Recovery::RECOVERABLE_MARKERS

      Observation = Data.define(
        :project, :slug, :folder, :state_file, :stage, :workflow, :marker,
        :marker_attrs, :state_file_mtime, :live_task_lock, :attempt_id,
        :task_generation, :suggested_command
      )

      def recover!(row:, project: nil, requestor: "operator", chat_id: nil,
                   update_id: nil, request_id: nil, observation_token: nil,
                   state_home: Hive::Paths.state_home, now: Time.now,
                   coordinator: nil)
        observation = observation(row, project: project)
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

      def recoverable_marker?(marker)
        Hive::Recovery.recoverable_marker?(marker)
      end

      def observation_token(row, project: nil, state_home: Hive::Paths.state_home,
                            coordinator: nil)
        normalized = observation(row, project: project)
        coordinator ||= Hive::Daemon::RecoveryCoordinator.new(state_home: state_home)
        coordinator.observation_token_for(normalized)
      end

      def observation(row, project: nil)
        folder = row_value(row, :folder)
        state_file = row_value(row, :state_file)
        if state_file.to_s.empty? && !folder.to_s.empty?
          state_file = Hive::Task.new(folder.to_s).state_file
        end
        Observation.new(
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
        observed = row_value(row, :state_file_mtime) ||
                   row_value(row, :observation_mtime) ||
                   row_value(row, :mtime)
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
