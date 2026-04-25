require "shellwords"
require "hive/stages"

module Hive
  class TaskAction
    ACTIONS = {
      inbox: {
        key: "ready_to_brainstorm",
        label: "Ready to brainstorm",
        command: "brainstorm"
      },
      brainstorm_waiting: {
        key: "needs_input",
        label: "Needs your input",
        command: "brainstorm"
      },
      brainstorm_complete: {
        key: "ready_to_plan",
        label: "Ready to plan",
        command: "plan"
      },
      plan_waiting: {
        key: "needs_input",
        label: "Needs your input",
        command: "plan"
      },
      plan_complete: {
        key: "ready_to_develop",
        label: "Ready to develop",
        command: "develop"
      },
      execute_findings: {
        key: "review_findings",
        label: "Review findings",
        command: "findings"
      },
      execute_waiting: {
        key: "needs_input",
        label: "Needs your input",
        command: "develop"
      },
      execute_complete: {
        key: "ready_for_pr",
        label: "Ready for PR",
        command: "pr"
      },
      execute_stale: {
        key: "recover_execute",
        label: "Needs recovery",
        command: "develop"
      },
      pr_waiting: {
        key: "needs_input",
        label: "Needs your input",
        command: "pr"
      },
      pr_complete: {
        key: "ready_to_archive",
        label: "Ready to archive",
        command: "archive"
      },
      done: {
        key: "archived",
        label: "Archived",
        command: nil
      },
      error: {
        key: "error",
        label: "Error",
        command: nil
      }
    }.freeze

    attr_reader :task, :marker, :project_name

    def initialize(task, marker, project_name: nil, project_count: 1, stage_collision: false)
      @task = task
      @marker = marker
      @project_name = project_name
      @project_count = project_count
      @stage_collision = stage_collision
    end

    def self.for(task, marker, **)
      new(task, marker, **)
    end

    def key
      action[:key]
    end

    def label
      action[:label]
    end

    def command
      verb = action[:command]
      return nil unless verb

      parts = [ "hive", verb, task.slug ]
      parts.concat([ "--project", project_name ]) if project_name && @project_count > 1
      parts.concat([ from_or_stage_option, stage_dir ]) if @stage_collision
      parts.shelljoin
    end

    def payload
      {
        "key" => key,
        "label" => label,
        "command" => command
      }
    end

    private

    def action
      return ACTIONS.fetch(:error) if marker.name == :error

      case task.stage_name
      when "inbox"
        ACTIONS.fetch(:inbox)
      when "brainstorm"
        marker.name == :complete ? ACTIONS.fetch(:brainstorm_complete) : ACTIONS.fetch(:brainstorm_waiting)
      when "plan"
        marker.name == :complete ? ACTIONS.fetch(:plan_complete) : ACTIONS.fetch(:plan_waiting)
      when "execute"
        execute_action
      when "pr"
        marker.name == :complete ? ACTIONS.fetch(:pr_complete) : ACTIONS.fetch(:pr_waiting)
      when "done"
        ACTIONS.fetch(:done)
      else
        ACTIONS.fetch(:error)
      end
    end

    def execute_action
      case marker.name
      when :execute_complete
        ACTIONS.fetch(:execute_complete)
      when :execute_stale
        ACTIONS.fetch(:execute_stale)
      when :execute_waiting
        if marker.attrs["findings_count"].to_i.positive?
          ACTIONS.fetch(:execute_findings)
        else
          ACTIONS.fetch(:execute_waiting)
        end
      else
        ACTIONS.fetch(:execute_waiting)
      end
    end

    def from_or_stage_option
      action[:command] == "findings" ? "--stage" : "--from"
    end

    def stage_dir
      "#{task.stage_index}-#{task.stage_name}"
    end
  end
end
