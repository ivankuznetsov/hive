require "shellwords"
require "hive/stages"
require "hive/workflows"

module Hive
  # Classifier that turns a (Task, Marker) pair into a user-facing
  # action: a stable key (matching `Hive::Schemas::TaskActionKind`),
  # a human label for `hive status` output, and a copy-paste-executable
  # `command` string for the next step.
  #
  # Used by `hive status` (per-row action grouping) and by
  # `hive run` / `hive approve` / `hive accept-finding` JSON
  # `next_action` emission.
  class TaskAction
    ACTIONS = {
      inbox: {
        key: Hive::Schemas::TaskActionKind::READY_TO_BRAINSTORM,
        label: "Ready to brainstorm",
        command: "brainstorm"
      },
      brainstorm_waiting: {
        key: Hive::Schemas::TaskActionKind::NEEDS_INPUT,
        label: "Needs your input",
        command: "brainstorm"
      },
      brainstorm_complete: {
        key: Hive::Schemas::TaskActionKind::READY_TO_PLAN,
        label: "Ready to plan",
        command: "plan"
      },
      plan_waiting: {
        key: Hive::Schemas::TaskActionKind::NEEDS_INPUT,
        label: "Needs your input",
        command: "plan"
      },
      plan_complete: {
        key: Hive::Schemas::TaskActionKind::READY_TO_DEVELOP,
        label: "Ready to develop",
        command: "develop"
      },
      execute_findings: {
        key: Hive::Schemas::TaskActionKind::REVIEW_FINDINGS,
        label: "Review findings",
        command: "findings"
      },
      execute_waiting: {
        key: Hive::Schemas::TaskActionKind::NEEDS_INPUT,
        label: "Needs your input",
        command: "develop"
      },
      execute_complete: {
        key: Hive::Schemas::TaskActionKind::READY_FOR_REVIEW,
        label: "Ready for review",
        command: "review"
      },
      execute_stale: {
        # Recovery path: the user must edit reviews/, lower task.md
        # frontmatter `pass:`, remove the EXECUTE_STALE marker, then
        # re-run. There is no single command that recovers; the closest
        # agent-callable step is reviewing the findings and toggling
        # accept-finding so the next run sees a smaller accepted set.
        key: Hive::Schemas::TaskActionKind::RECOVER_EXECUTE,
        label: "Needs recovery",
        command: "findings"
      },
      review_waiting: {
        key: Hive::Schemas::TaskActionKind::NEEDS_INPUT,
        label: "Needs your input",
        command: "review"
      },
      review_complete: {
        key: Hive::Schemas::TaskActionKind::READY_FOR_PR,
        label: "Ready for PR",
        command: "pr"
      },
      review_stale: {
        key: Hive::Schemas::TaskActionKind::RECOVER_REVIEW,
        label: "Needs recovery",
        command: nil
      },
      pr_waiting: {
        key: Hive::Schemas::TaskActionKind::NEEDS_INPUT,
        label: "Needs your input",
        command: "pr"
      },
      pr_complete: {
        key: Hive::Schemas::TaskActionKind::READY_TO_ARCHIVE,
        label: "Ready to archive",
        command: "archive"
      },
      done: {
        key: Hive::Schemas::TaskActionKind::ARCHIVED,
        label: "Archived",
        command: nil
      },
      agent_running: {
        # Marker is `:agent_working` — a `hive run` is in flight. Surfacing
        # a workflow command here would send the user (or an agent loop)
        # straight into ConcurrentRunError on every retry. The right
        # action is wait-and-watch.
        key: Hive::Schemas::TaskActionKind::AGENT_RUNNING,
        label: "Agent running",
        command: nil
      },
      error: {
        key: Hive::Schemas::TaskActionKind::ERROR,
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

    # Returns a copy-paste-executable shell command, or nil for actions
    # whose state requires manual recovery (agent_running, archived, error).
    #
    # Workflow-verb commands ALWAYS include `--from <stage>`: that's the
    # idempotency lever — a retry after a successful advance fails with
    # WRONG_STAGE (4) instead of silently advancing twice. Generic verbs
    # (findings/accept-finding/reject-finding) only include `--stage`
    # when slug-stage ambiguity actually exists.
    def command
      verb = action[:command]
      return nil unless verb

      parts = [ "hive", verb, task.slug ]
      parts.concat([ "--project", project_name ]) if project_name && @project_count > 1
      parts.concat([ from_or_stage_option(verb), stage_dir ]) if include_stage_filter?(verb)
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
      # `:agent_working` overrides every (stage, marker) pair — a live
      # agent run on the task pre-empts whatever workflow advice the
      # state-machine would otherwise produce.
      return ACTIONS.fetch(:agent_running) if marker.name == :agent_working
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
      when "review"
        review_action
      when "pr"
        marker.name == :complete ? ACTIONS.fetch(:pr_complete) : ACTIONS.fetch(:pr_waiting)
      when "done"
        ACTIONS.fetch(:done)
      else
        ACTIONS.fetch(:error)
      end
    end

    def review_action
      case marker.name
      when :review_complete
        ACTIONS.fetch(:review_complete)
      when :review_stale, :review_ci_stale, :review_error
        ACTIONS.fetch(:review_stale)
      else
        ACTIONS.fetch(:review_waiting)
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

    # Workflow verbs (brainstorm/plan/develop/pr/archive) use --from for
    # the source-stage assertion; generic verbs (findings/accept-finding/
    # reject-finding) use --stage for ambiguity disambiguation.
    def from_or_stage_option(verb)
      Hive::Workflows.workflow_verb?(verb) ? "--from" : "--stage"
    end

    # Workflow verbs always carry --from for retry idempotency.
    # Generic verbs only when ambiguity demands disambiguation.
    def include_stage_filter?(verb)
      Hive::Workflows.workflow_verb?(verb) || @stage_collision
    end

    def stage_dir
      "#{task.stage_index}-#{task.stage_name}"
    end
  end
end
