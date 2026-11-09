# frozen_string_literal: true

require "digest"
require "hive/operational_action"
require "hive/attempts/generation"
require "hive/recovery/retry_policy"

module Hive
  # Effect verification shared by admission and retained worker authority.
  module WorkflowAdmission
    VALID_TERMINAL_MARKERS = %i[complete execute_complete review_complete].freeze
    module_function

    def generation_for(task, project:)
      Hive::Attempts::Generation.resolve(task: task, project: project,
        intended_stage: stage_for(task)).ownership_generation
    end

    def effect_for(task:, row:, action_id:, project:)
      if action_id == Hive::OperationalAction::RETRY_ACTION_ID
        verb = Hive::Recovery::RetryPolicy.verb_for(row.fetch("stage"),
          workflow: row.fetch("workflow"), project: project.fetch("name"))
        unless verb == "run" || Hive::OperationalAction::STAGE_ACTIONS.value?(verb)
          raise Hive::OperationalActionUsageError, "this recovery must be performed locally"
        end
        if verb != "run"
          transition = Hive::Workflows.for_verb(verb)
          if transition[:force_source] && row.fetch("stage") != transition.fetch(:target)
            raise Hive::OperationalActionUsageError, "this recovery requires force; retry locally"
          end
        end
        return { "kind" => "retry", "verb" => verb, "stage" => row.fetch("stage"), "force" => false }
      end
      action = row.fetch("action")
      if (verb = Hive::OperationalAction::STAGE_ACTIONS[action])
        transition = Hive::Workflows.for_verb(verb)
        if transition[:force_source] && row.fetch("stage") != transition.fetch(:target)
          raise Hive::OperationalActionUsageError, "this transition requires force; advance locally"
        end
        { "kind" => "stage_action", "verb" => verb, "force" => false }
      elsif action == Hive::Schemas::TaskActionKind::OUTCOME_EVIDENCE_REWORK
        { "kind" => "evidence_rework", "force" => false }
      elsif action == "ready_to_run"
        { "kind" => "run", "force" => false }
      elsif action == "ready_to_advance"
        if row.fetch("marker") == "none"
          raise Hive::OperationalActionUsageError, "this transition requires force; advance locally"
        end
        { "kind" => "approve", "force" => false }
      else
        raise Hive::OperationalActionUsageError, "unsupported remote workflow effect"
      end
    end

    def verify_action!(task:, project:, action_id:, observation:, authority:)
      unless authority.fetch("project") == project && authority.fetch("task_id").to_s == task.id.to_s &&
             authority.fetch("slug") == task.slug
        raise Hive::StaleOperationalObservation, "task identity changed before remote execution"
      end
      row = Hive::OperationalAction.observed_row(task, project: project)
      expected = effect_for(task: task, row: row, action_id: action_id, project: { "name" => project })
      unless expected == authority.fetch("effect") &&
             execution_observation(task, row) == authority.fetch("execution_observation") &&
             action_id == authority.fetch("action_id") && observation == authority.fetch("observation")
        raise Hive::StaleOperationalObservation, "workflow effect changed before remote execution"
      end
      true
    rescue Hive::OperationalActionUsageError
      raise Hive::StaleOperationalObservation, "workflow effect changed before remote execution"
    end

    def execution_observation(task, row)
      row.slice("stage", "workflow", "marker", "attrs", "mtime", "action").merge(
        "state_sha256" => File.file?(task.state_file) ? Digest::SHA256.file(task.state_file).hexdigest : nil,
        "task_input_epoch" => Hive::Attempts::Generation.current_task_input_epoch(task)
      )
    end

    def verify_approval!(task:, project:, authority:)
      stage = stage_for(task)
      unless authority.fetch("project") == project && authority.fetch("slug") == task.slug &&
             authority.fetch("task_id").to_s == task.id.to_s && authority.fetch("stage") == stage &&
             authority.fetch("generation") == generation_for(task, project: project)
        raise Hive::StaleOperationalObservation, "approval stage or generation changed"
      end
      marker = Hive::Markers.current(task.state_file)
      unless VALID_TERMINAL_MARKERS.include?(marker.name)
        raise Hive::OperationalActionUsageError, "this transition requires a terminal marker; advance locally"
      end
      true
    end

    def stage_for(task) = "#{task.stage_index}-#{task.stage_name}"
  end
end
