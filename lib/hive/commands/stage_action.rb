require "hive/commands/approve"
require "hive/commands/run"
require "hive/markers"
require "hive/stages"
require "hive/task_resolver"

module Hive
  module Commands
    class StageAction
      ACTIONS = {
        "brainstorm" => { target: "2-brainstorm", source: "1-inbox", force_source: true },
        "plan" => { target: "3-plan", source: "2-brainstorm" },
        "develop" => { target: "4-execute", source: "3-plan" },
        "pr" => { target: "5-pr", source: "4-execute" },
        "archive" => { target: "6-done", source: "5-pr" }
      }.freeze

      def initialize(verb, target, project: nil, from: nil, json: false)
        @verb = verb
        @target = target
        @project_filter = project
        @from = from
        @json = json
      end

      def call
        config = ACTIONS.fetch(@verb)
        task = Hive::TaskResolver.new(
          @target,
          project_filter: @project_filter,
          stage_filter: @from
        ).resolve

        current_stage = stage_dir(task)
        if current_stage == config.fetch(:target)
          return Hive::Commands::Run.new(task.folder, project: @project_filter, json: @json).call
        end

        unless current_stage == config.fetch(:source)
          raise Hive::WrongStage,
                "#{@verb} expects #{config.fetch(:source)} or #{config.fetch(:target)}, " \
                "but #{task.slug} is at #{current_stage}"
        end

        validate_marker!(task, config)
        new_folder = File.join(task.hive_state_path, "stages", config.fetch(:target), task.slug)
        Hive::Commands::Approve.new(
          task.folder,
          to: config.fetch(:target),
          from: current_stage,
          project: @project_filter,
          force: config[:force_source],
          json: false
        ).call
        Hive::Commands::Run.new(new_folder, project: @project_filter, json: @json).call
      end

      private

      def validate_marker!(task, config)
        return if config[:force_source]

        marker = Hive::Markers.current(task.state_file)
        return if terminal_marker?(marker)

        next_command = "hive #{@verb} #{task.slug} --from #{stage_dir(task)}"
        raise Hive::WrongStage,
              "#{@verb} cannot advance #{task.slug} from #{stage_dir(task)} while marker is :#{marker.name}; " \
              "finish the current stage first, then run `#{next_command}`"
      end

      def terminal_marker?(marker)
        marker.name == :complete || marker.name == :execute_complete
      end

      def stage_dir(task)
        "#{task.stage_index}-#{task.stage_name}"
      end
    end
  end
end
