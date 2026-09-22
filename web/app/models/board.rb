require "hive/stage_label"

class Board
  DEFAULT_WORKFLOW = Hive::Config::DEFAULTS.fetch("default_workflow")

  Column = Data.define(:stage, :label, :tasks, :terminal) do
    def folded_by_default? = tasks.empty? || terminal
  end

  Band = Data.define(:project, :workflow_id, :columns, :daemon_enabled, :error) do
    def task_count = columns.sum { |column| column.tasks.size }

    def unavailable? = error.present?

    def availability_message
      return "Workflow unavailable. Observed task stages remain visible." if error == "workflow_unavailable"

      "Project status unavailable: #{error.to_s.humanize.downcase}."
    end
  end

  StageSnapshot = Data.define(:dir, :name)
  WorkflowSnapshot = Data.define(:stages)

  attr_reader :bands, :metadata

  def initialize(projects, metadata: nil)
    @snapshot_metadata = metadata
    @metadata = {}
    @bands = projects.flat_map { |project| bands_for(project) }
  end

  def empty? = bands.empty?

  private

  def bands_for(project)
    saved = @snapshot_metadata&.fetch(project.name, {})
    default_workflow = saved ? saved.fetch("default_workflow", DEFAULT_WORKFLOW) : default_workflow_for(project)
    tasks_by_workflow = project.active_tasks.group_by do |task|
      task["workflow"].presence || default_workflow
    end
    tasks_by_workflow[default_workflow] = [] if tasks_by_workflow.empty?
    daemon_enabled = saved ? saved.fetch("daemon_enabled", true) : project.daemon_enabled?
    workflow_ids = tasks_by_workflow.keys.sort
    workflows = if saved
      saved.fetch("workflows", {}).transform_values do |stages|
        WorkflowSnapshot.new(stages: stages.map { |stage| StageSnapshot.new(**stage.symbolize_keys) }) if stages
      end
    else
      workflows_for(project, (workflow_ids + [ default_workflow ]).uniq)
    end
    unavailable_workflows = saved ? saved.fetch("unavailable_workflows", []) : workflows.select { |_, workflow| workflow.nil? }.keys
    @metadata[project.name] = {
      "default_workflow" => default_workflow, "daemon_enabled" => daemon_enabled,
      "unavailable_workflows" => unavailable_workflows,
      "workflows" => workflows.transform_values do |workflow|
        workflow&.stages&.map { |stage| { "dir" => stage.dir, "name" => stage.name } }
      end
    }

    workflow_ids.map do |workflow_id|
      tasks = tasks_by_workflow.fetch(workflow_id)
      workflow = workflows[workflow_id]
      Band.new(
        project:,
        workflow_id:,
        columns: columns_for(workflow, tasks),
        daemon_enabled:,
        error: project["error"].presence || ("workflow_unavailable" if unavailable_workflows.include?(workflow_id) || (!workflow && saved != {}))
      )
    end
  end

  def default_workflow_for(project)
    project.default_workflow || DEFAULT_WORKFLOW
  rescue KeyError
    DEFAULT_WORKFLOW
  end

  def columns_for(workflow, tasks)
    configured_stages = workflow&.stages.to_a
    tasks_by_stage = tasks.group_by { |task| task["stage"].presence || "unknown" }
    configured_dirs = configured_stages.map(&:dir)

    # Producing a terminal deliverable and completing it are different states.
    # Keep pending delivery in its real stage; Done is only a presentation group.
    terminal = configured_stages.last
    completed = []
    if terminal && terminal.name != "done"
      completed, pending = tasks_by_stage.fetch(terminal.dir, []).partition do |task|
        task["action"] == "archived"
      end
      tasks_by_stage[terminal.dir] = pending
    end

    columns = configured_stages.map do |stage|
      Column.new(stage: stage.dir, label: Hive::StageLabel.format(stage.name), tasks: tasks_by_stage.fetch(stage.dir, []),
                 terminal: stage == configured_stages.last)
    end
    (tasks_by_stage.keys - configured_dirs).sort_by { |stage| stage_sort_key(stage) }.each do |stage|
      columns << Column.new(stage:, label: Hive::StageLabel.format(stage), tasks: tasks_by_stage.fetch(stage), terminal: false)
    end
    columns << Column.new(stage: "completed", label: "Done", tasks: completed, terminal: true) if completed.any?
    columns.presence || [ Column.new(stage: "unavailable", label: "Workflow unavailable", tasks:, terminal: false) ]
  end

  def workflows_for(project, workflow_ids)
    Hive::Workflows::Project.synchronize do
      Hive::Workflows::Project.load!(project.path, config: project.config) if project["path"].present?
      workflow_ids.to_h do |workflow_id|
        workflow = Hive::Workflows::Registry.fetch(workflow_id.to_sym)
        [ workflow_id, workflow ]
      rescue Hive::Workflows::UnknownWorkflow => e
        log_unavailable_workflow(project, workflow_id, e)
        [ workflow_id, nil ]
      end
    end
  rescue Hive::ConfigError, Psych::Exception, SystemCallError, IOError => e
    workflow_ids.each { |workflow_id| log_unavailable_workflow(project, workflow_id, e) }
    workflow_ids.index_with { nil }
  end

  def log_unavailable_workflow(project, workflow_id, error)
    Rails.logger.warn(
      "board workflow unavailable for #{project.name}/#{workflow_id}: #{error.class}: #{error.message}"
    )
  end

  def stage_sort_key(stage)
    index = stage.to_s.to_i
    [ index.zero? ? Float::INFINITY : index, stage.to_s ]
  end
end
