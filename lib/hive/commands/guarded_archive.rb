require "hive/commands/approve"
require "hive/commands/run"
require "hive/markers"
require "hive/stages"
require "hive/modules/event_publisher"

module Hive
  module Commands
    # The one internal guarded-archive protocol. Evidence closure retires a
    # task from any active stage through this single boundary: the caller
    # supplies a pre-transition guard (rechecked inside the atomic task move)
    # and an optional locked-task observation; the protocol owns the
    # resume-at-terminal versus guarded-move-and-run mechanics and the
    # internal no-rebase run policy. Ordinary verb dispatch in StageAction
    # never enters here, and this protocol holds no knowledge of closure
    # receipts — receipt semantics live entirely with their owner.
    class GuardedArchive
      def self.call(task, current_stage:, target_stage:, project: nil,
                    transition_guard:, observation_guard: nil)
        new(
          task: task,
          current_stage: current_stage,
          target_stage: target_stage,
          project: project,
          transition_guard: transition_guard,
          observation_guard: observation_guard
        ).call
      end

      def initialize(task:, current_stage:, target_stage:, project: nil,
                     transition_guard:, observation_guard:)
        @task = task
        @current_stage = current_stage
        @target_stage = target_stage
        @project = project
        @transition_guard = transition_guard
        @observation_guard = observation_guard
      end

      def call
        @transition_guard.call(@task)

        if @current_stage == @target_stage
          return resume_at_terminal
        end

        guarded_move_and_run
      end

      private

      def resume_at_terminal
        marker = Hive::Markers.current(@task.state_file)
        return publish_completion(@task) if marker.name == :complete ||
                                               inert_controller_terminal?(@task)

        run_at(@task.folder)
        resumed = Hive::Task.new(@task.folder)
        publish_completion(resumed)
        resumed
      end

      def guarded_move_and_run
        new_folder = File.join(
          @task.hive_state_path, "stages", @target_stage, @task.slug
        )
        Hive::Commands::Approve.new(
          @task.folder,
          to: @target_stage,
          from: @current_stage,
          project: @project,
          force: true,
          json: false,
          quiet: true,
          observation_guard: lambda do |locked_task|
            @transition_guard.call(locked_task)
            @observation_guard&.call(locked_task)
          end
        ).call
        closed = Hive::Task.new(new_folder)
        unless inert_controller_terminal?(closed)
          run_at(new_folder)
          closed = Hive::Task.new(new_folder)
        end
        publish_completion(closed)
        closed
      end

      def run_at(folder)
        Hive::Commands::Run.new(
          folder,
          project: @project,
          json: false,
          quiet: true,
          no_rebase: true
        ).call
      end

      # Agent-owned terminal stages prove completion with :complete. A
      # controller-owned inert terminal has no runner or marker; reaching it
      # through this guarded protocol is itself the terminal side effect.
      def publish_completion(task)
        stage_dir = "#{task.stage_index}-#{task.stage_name}"
        return unless task.workflow.stages.last.dir == stage_dir
        return unless Hive::Markers.current(task.state_file).name == :complete ||
                      inert_controller_terminal?(task)

        publisher.task_completed(task)
      end

      def inert_controller_terminal?(task)
        terminal = task.workflow.stages.last
        task.workflow.controller? && terminal.kind == :inert &&
          terminal.dir == "#{task.stage_index}-#{task.stage_name}"
      end

      def publisher
        @publisher ||= Hive::Modules::EventPublisher.new
      end
    end
  end
end
