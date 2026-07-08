require "fileutils"
require "hive/markers"
require "hive/stages/base"
require "hive/stages/council/reviewer"
require "hive/stages/council/revise"
require "hive/stages/council/triage"

module Hive
  module Stages
    module Council
      module_function

      def run!(task, cfg)
        cfg ||= {}
        stage = task.workflow.stage_named(task.stage_name)
        stage or raise Hive::StageError, "no council stage #{task.stage_name}"
        output_path = File.join(task.folder, stage.state_file)
        target_path = resolve_target_path(task, stage)

        unless File.exist?(target_path) && File.size(target_path).positive?
          Hive::Markers.set(output_path, :error, reason: "missing_input", input: target_path)
          marker = Hive::Markers.current(output_path)
          return { commit: action_for(marker.name), status: marker.name }
        end

        round = next_round(task.folder, stage)
        loop do
          Hive::Markers.set(output_path, :agent_working, phase: "council", round: round)
          review_paths = stage.reviewers.map do |reviewer|
            Hive::Stages::Council::Reviewer.run!(
              task: task,
              cfg: cfg,
              stage: stage,
              reviewer: reviewer,
              round: round,
              target_path: target_path
            )
          end
          triage = Hive::Stages::Council::Triage.run!(
            stage: stage,
            review_paths: review_paths,
            round: round,
            target_path: target_path,
            task_folder: task.folder
          )

          if triage.ready
            Hive::Markers.set(output_path, :complete, round: round, triage: triage.path)
            marker = Hive::Markers.current(output_path)
            return { commit: action_for(marker.name), status: marker.name }
          end

          revise = stage.council.revise
          unless stage.council.exit_rule == :consensus && revise
            Hive::Markers.set(output_path, :waiting, reason: "needs_revision", round: round, triage: triage.path)
            marker = Hive::Markers.current(output_path)
            return { commit: action_for(marker.name), status: marker.name }
          end

          if round >= stage.council.max_rounds
            Hive::Markers.set(output_path, :waiting, reason: "max_rounds", round: round, triage: triage.path)
            marker = Hive::Markers.current(output_path)
            return { commit: action_for(marker.name), status: marker.name }
          end

          Hive::Stages::Council::Revise.run!(
            task: task,
            cfg: cfg,
            stage: stage,
            revise: revise,
            round: round,
            target_path: target_path,
            triage_path: triage.path
          )
          round += 1
        end
      rescue Hive::StageError => e
        Hive::Markers.set(output_path || task.state_file, :error, reason: "council_failed", message: e.message.to_s[0, 200])
        marker = Hive::Markers.current(output_path || task.state_file)
        { commit: action_for(marker.name), status: marker.name }
      end

      def resolve_target_path(task, stage)
        input = stage.input
        return File.expand_path(input, task.folder) if input

        previous = previous_stage(task.workflow, stage)
        raise Hive::StageError, "council stage #{stage.name} has no prior stage to review" unless previous

        File.join(task.folder, previous.state_file)
      end

      def previous_stage(workflow, stage)
        index = workflow.stages.find_index { |candidate| candidate.name == stage.name }
        return nil unless index && index.positive?

        workflow.stages[index - 1]
      end

      def next_round(task_folder, stage)
        pattern = File.join(task_folder, "reviews", "#{triage_basename(stage)}-*.md")
        rounds = Dir.glob(pattern).filter_map do |path|
          File.basename(path, ".md")[/-(\d+)\z/, 1]&.to_i
        end
        rounds.max.to_i + 1
      end

      def triage_basename(stage)
        File.basename(stage.council.triage_output || "reviews/triage.md", ".md")
      end

      def action_for(marker_name)
        case marker_name
        when :waiting then "round_waiting"
        when :complete then "complete"
        when :error then "error"
        when :none then nil
        else marker_name.to_s
        end
      end
    end
  end
end
