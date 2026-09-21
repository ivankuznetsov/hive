class StatusController < ApplicationController
  VIEWS = %w[board grid].freeze
  VIEW_COOKIE = :hive_status_view
  helper_method :status_filter_path

  def index
    explicit_view = params[:view].to_s.presence_in(VIEWS)
    saved_view = cookies.signed[VIEW_COOKIE].to_s.presence_in(VIEWS)
    @status_view = explicit_view || saved_view || "board"
    page_snapshot = StatusBroadcaster.snapshot_with_version
    @status_page_snapshot = page_snapshot
    @payload = page_snapshot.payload
    @status_version = page_snapshot.version
    @status_fresh = page_snapshot.fresh?
    @status_display_fresh = @status_fresh || page_snapshot.availability == "cached"
    @projects = StatusBroadcaster.projects(@payload)
    requested_project = params[:project].to_s.presence
    @selected_project = @projects.find { |project| project.name == requested_project }
    return redirect_to status_filter_path(project: nil) if requested_project && !@selected_project

    @visible_projects = @selected_project ? [ @selected_project ] : @projects
    if @selected_project && @selected_project["hive_state_path"].present? && !@status_page_snapshot.unavailable?
      history = StatusBroadcaster.projects(StatusBroadcaster.archive_snapshot(project: @selected_project)).first
      if history
        completed = history.attributes.fetch("tasks", []).map { |task| task.merge("archive_source" => true) }
        tasks = (@selected_project.attributes.fetch("tasks", []) + completed).index_by { |task| task.fetch("slug") }.values
        @visible_projects = [ Project.new(@selected_project.attributes.merge(
          "tasks" => tasks, "error" => @selected_project["error"] || history["error"]
        )) ]
      end
    end
    order = TaskDisplay::STATES.keys
    @visible_projects = @visible_projects.map do |project|
      tasks = project.attributes.fetch("tasks", []).sort_by do |attributes|
        display = TaskDisplay.new(Task.new(project: project, attributes: attributes), fresh: @status_display_fresh)
        [ order.index(display.state), -Time.parse(attributes["mtime"].to_s).to_i ]
      rescue ArgumentError
        [ order.index(display.state), 0 ]
      end
      Project.new(project.attributes.merge("tasks" => tasks))
    end
    @task_counts = @visible_projects.flat_map(&:active_tasks).map { |task| TaskDisplay.new(task, fresh: @status_display_fresh).state }.tally
    @task_state = params[:state].to_s.presence_in(order)
    if @task_state
      @visible_projects = @visible_projects.filter_map do |project|
        tasks = project.attributes.fetch("tasks", []).select do |attributes|
          TaskDisplay.new(Task.new(project: project, attributes: attributes), fresh: @status_display_fresh).state == @task_state
        end
        Project.new(project.attributes.merge("tasks" => tasks)) if tasks.any? || project["error"].present?
      end
    end
    @board = Board.new(@visible_projects) if @status_view == "board"
    @daemon_status = daemon_status
  end

  def archive
    requested_project = params[:project].to_s.presence
    if requested_project
      @projects = Project.all
      @selected_project = @projects.find { |project| project.name == requested_project }
      return redirect_to status_filter_path(project: nil) unless @selected_project

      @payload = StatusBroadcaster.archive_snapshot(project: @selected_project)
      @visible_projects = StatusBroadcaster.projects(@payload)
    else
      @payload = StatusBroadcaster.archive_snapshot
      @projects = StatusBroadcaster.projects(@payload)
      @visible_projects = @projects
    end
    @board = Board.new(@visible_projects) if params[:view] == "board"
  end

  private

  def status_filter_path(**changes)
    query = request.query_parameters.merge(changes.stringify_keys).compact
    query.empty? ? request.path : "#{request.path}?#{query.to_query}"
  end

  # Build the daemon-status envelope in-process. StatusReport is the same
  # producer behind `hive daemon status --json`, returning the envelope as a
  # Hash — so we never reassign the process-global $stdout (which under
  # threaded Puma would capture/suppress/interleave concurrent requests'
  # output). `safe_payload` never raises on a not-running daemon.
  def daemon_status
    require "hive/daemon/status_report"
    Hive::Daemon::StatusReport.new.safe_payload
  rescue StandardError => e
    Rails.logger.warn("daemon_status probe failed: #{e.class}: #{e.message}")
    { "ok" => false, "running" => false, "message" => e.message }
  end
end
