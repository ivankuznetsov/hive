require "fileutils"
require "hive/markers"
require "hive/workflow"
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

        # Pre-flight resume (plan U4). Inspect the current marker BEFORE opening a
        # round so re-running behaves like the design flowchart's pre-flight node:
        #   - :complete   -> the council is done; short-circuit without re-spawning
        #                    reviewers (which would burn cost and could knock a
        #                    finished stage back to :waiting).
        #   - :waiting    -> resume by re-triaging the SAME round (e.g. after a
        #                    human edits the document), not by opening a fresh one.
        preflight = Hive::Markers.current(output_path)
        return { commit: action_for(:complete), status: :complete } if preflight.name == :complete

        Hive::Config.validate_council_model_controls!(cfg, stage)
        target_path = resolve_target_path(task, stage)

        unless File.exist?(target_path) && File.size(target_path).positive?
          Hive::Markers.set(output_path, :error, reason: "missing_input", input: target_path)
          marker = Hive::Markers.current(output_path)
          return { commit: action_for(marker.name), status: marker.name }
        end

        round =
          if preflight.name == :waiting && preflight.attrs["round"].to_i.positive?
            preflight.attrs["round"].to_i
          else
            next_round(task.folder, stage)
          end
        loop do
          # Include pid/started for parity with the agent runner's working
          # marker (Hive::Agent#run!), so `hive status` can show which runner
          # owns an in-flight council rather than just the phase/round.
          Hive::Markers.set(output_path, :agent_working, phase: "council", round: round,
                            pid: Process.pid, started: Time.now.utc.iso8601)
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
      rescue SystemCallError => e
        # A file the council reads (a reviewer/revise instruction, the triage
        # artifact, or the target document) can be renamed/deleted/chmod'd
        # between descriptor parse and this run. Those `File.read`s raise a
        # SystemCallError (e.g. Errno::ENOENT), which is NOT a Hive::StageError
        # and would otherwise escape the runner with no marker — leaving the row
        # to silently re-classify as ready_to_run. Stamp an attributed :error
        # marker instead, mirroring Hive::Stages::Agent's defensive read.
        Hive::Markers.set(output_path || task.state_file, :error, reason: "council_io_error", message: e.message.to_s[0, 200])
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
        # Derive the glob dir from triage_output (Triage#triage_path writes to
        # File.dirname(triage_output)); hardcoding "reviews" here would never
        # match a custom triage_output dir, so next_round would always return 1
        # and each round would overwrite <name>-01.md, breaking round tracking.
        triage_output = stage.council.triage_output || Hive::Workflow::DEFAULT_TRIAGE_OUTPUT
        dir = File.dirname(triage_output)
        pattern = File.join(task_folder, dir, "#{triage_basename(stage)}-*.md")
        rounds = Dir.glob(pattern).filter_map do |path|
          File.basename(path, ".md")[/-(\d+)\z/, 1]&.to_i
        end
        rounds.max.to_i + 1
      end

      def triage_basename(stage)
        File.basename(stage.council.triage_output || Hive::Workflow::DEFAULT_TRIAGE_OUTPUT, ".md")
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
