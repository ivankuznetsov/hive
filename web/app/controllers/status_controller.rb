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
      ProjectArchive.request(@selected_project.attributes)
      history = @payload.dig("project_archives", @selected_project.name)
      @history_loading = history.nil?
      @visible_projects = [ @selected_project.with_history(history) ]
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
    @board = Board.new(@visible_projects, metadata: @payload.fetch("board_metadata", {})) if @status_view == "board"
    @daemon_status = @payload.fetch("daemon_status", {})
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
end
