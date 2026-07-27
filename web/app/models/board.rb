require "hive/stage_label"

class Board
  DEFAULT_WORKFLOW = Hive::Config::DEFAULTS.fetch("default_workflow")

  Column = Data.define(:stage, :label, :tasks)

  Band = Data.define(
    :project, :workflow_id, :columns, :daemon_enabled, :error,
    :hidden_archived_task_count
  ) do
    def task_count = columns.sum { |column| column.tasks.size }

    def unavailable? = error.present?

    def availability_message
      return "Workflow unavailable. Observed task stages remain visible." if error == "workflow_unavailable"

      "Project status unavailable: #{error.to_s.humanize.downcase}."
    end
  end

  attr_reader :bands

  def initialize(projects)
    @bands = projects.flat_map { |project| bands_for(project) }
  end

  def empty? = bands.empty?

  private

  def bands_for(project)
    default_workflow = default_workflow_for(project)
    tasks_by_workflow = project.active_tasks.group_by do |task|
      task["workflow"].presence || default_workflow
    end
    tasks_by_workflow[default_workflow] = [] if tasks_by_workflow.empty?
    daemon_enabled = project.daemon_enabled?
    workflow_ids = tasks_by_workflow.keys.sort
    workflows = workflows_for(project, workflow_ids)

    workflow_ids.map.with_index do |workflow_id, index|
      tasks = tasks_by_workflow.fetch(workflow_id)
      workflow = workflows[workflow_id]
      Band.new(
        project:,
        workflow_id:,
        columns: columns_for(workflow, tasks),
        daemon_enabled:,
        error: project["error"].presence || ("workflow_unavailable" unless workflow),
        # The count is project-scoped, so attach it to exactly one band. A
        # mixed-workflow project must render one summary, not one per band.
        hidden_archived_task_count: index.zero? ? project.hidden_archived_task_count : 0
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

    columns = configured_stages.map do |stage|
      Column.new(stage: stage.dir, label: Hive::StageLabel.format(stage.name), tasks: tasks_by_stage.fetch(stage.dir, []))
    end
    (tasks_by_stage.keys - configured_dirs).sort_by { |stage| stage_sort_key(stage) }.each do |stage|
      columns << Column.new(stage:, label: Hive::StageLabel.format(stage), tasks: tasks_by_stage.fetch(stage))
    end
    columns.presence || [ Column.new(stage: "unavailable", label: "Workflow unavailable", tasks:) ]
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
