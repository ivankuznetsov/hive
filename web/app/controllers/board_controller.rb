class BoardController < ApplicationController
  GROUPS = %w[none agent dependency project].freeze

  def index
    @work_view = "board"
    prepare_board
  end

  protected

  def prepare_board
    @payload = StatusBroadcaster.snapshot
    @projects = StatusVisibility.projects(@payload)
    @filters = normalized_filters
    @bands = build_bands
    @project_options = @projects.map { |project| project["name"] }.compact.sort
    @workflow_options = @projects.flat_map { |project| project.fetch("workflows", []).map { |workflow| workflow["id"] } }
      .compact.uniq.sort
    @state_options = @projects.flat_map { |project| project.fetch("tasks", []).map { |task| task["dominant_state"] } }
      .compact.uniq.sort
    @agent_options = @projects.flat_map { |project| project.fetch("tasks", []).filter_map { |task| task_agent(task) } }
      .uniq.sort
    @daemon_status = daemon_status
  end

  private

  def normalized_filters
    group = params[:group].to_s
    group = "none" unless GROUPS.include?(group)
    {
      "project" => params[:project].to_s,
      "workflow" => params[:workflow].to_s,
      "state" => params[:state].to_s,
      "agent" => params[:agent].to_s,
      "q" => params[:q].to_s.strip,
      "group" => group
    }
  end

  def build_bands
    @projects.filter_map do |project|
      next if @filters["project"].present? && @filters["project"] != project["name"]

      definitions = project.fetch("workflows", []).index_by { |workflow| workflow["id"].to_s }
      tasks = project.fetch("tasks", [])
      tasks.group_by { |task| task["workflow"].presence || "coding" }.filter_map do |workflow_id, workflow_tasks|
        next if @filters["workflow"].present? && @filters["workflow"] != workflow_id

        workflow = definitions[workflow_id] || inferred_workflow(workflow_id, workflow_tasks)
        filtered = workflow_tasks.select { |task| matches_filters?(task) }
        next if filtered.empty?

        {
          "project" => project,
          "workflow" => workflow,
          "tasks" => filtered.sort_by { |task| [ task["state_rank"].to_i, -task["age_seconds"].to_i ] }
        }
      end
    end.flatten
  end

  def matches_filters?(task)
    return false if @filters["state"].present? && @filters["state"] != task["dominant_state"]
    return false if @filters["agent"].present? && @filters["agent"] != task_agent(task)
    return true if @filters["q"].blank?

    haystack = [ task["display_name"], task["slug"], task["action_label"] ].compact.join(" ").downcase
    haystack.include?(@filters["q"].downcase)
  end

  def inferred_workflow(workflow_id, tasks)
    stages = tasks.map { |task| task["stage"].to_s }.uniq.sort_by { |stage| stage.to_i }
    {
      "id" => workflow_id,
      "dependency_gate_stage" => stages.last,
      "stages" => stages.each_with_index.map do |dir, index|
        { "name" => dir.split("-", 2).last, "dir" => dir, "index" => index + 1, "kind" => nil }
      end
    }
  end

  def task_agent(task)
    task.dig("implementation_identity", "stages", "execute", "provider")
  end

  def daemon_status
    require "hive/daemon/status_report"
    Hive::Daemon::StatusReport.new.safe_payload
  rescue StandardError => e
    Rails.logger.warn("daemon_status probe failed: #{e.class}: #{e.message}")
    { "ok" => false, "running" => false, "message" => e.message }
  end
end
