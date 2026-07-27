class StatusController < ApplicationController
  VIEWS = %w[board grid].freeze
  VIEW_COOKIE = :hive_status_view
  helper_method :status_project_filter_path

  def index
    explicit_view = params[:view].to_s.presence_in(VIEWS)
    saved_view = cookies.signed[VIEW_COOKIE].to_s.presence_in(VIEWS)
    @status_view = explicit_view || saved_view || "board"
    page_snapshot = StatusBroadcaster.snapshot_with_version
    @status_page_snapshot = page_snapshot
    @payload = page_snapshot.payload
    @status_version = page_snapshot.version
    @status_fresh = page_snapshot.fresh?
    @projects = StatusBroadcaster.projects(@payload)
    requested_project = params[:project].to_s.presence
    @selected_project = @projects.find { |project| project.name == requested_project }
    return redirect_to status_project_filter_path(nil) if requested_project && !@selected_project

    @visible_projects = @selected_project ? [ @selected_project ] : @projects
    @board = Board.new(@visible_projects) if @status_view == "board"
    @daemon_status = daemon_status
  end

  def archive
    @payload = StatusBroadcaster.archive_snapshot
    @projects = StatusBroadcaster.projects(@payload)
    requested_project = params[:project].to_s.presence
    @selected_project = @projects.find { |project| project.name == requested_project }
    return redirect_to status_project_filter_path(nil) if requested_project && !@selected_project

    @visible_projects = @selected_project ? [ @selected_project ] : @projects
  end

  private

  def status_project_filter_path(project)
    query = request.query_parameters.except("project")
    query["project"] = project if project.present?
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
