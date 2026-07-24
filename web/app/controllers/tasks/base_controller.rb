class Tasks::BaseController < ApplicationController
  before_action :load_project
  before_action :load_task

  private

  def load_project
    @project = find_project!(params[:project])
  end

  def load_task
    page_snapshot = StatusBroadcaster.current_page_snapshot
    @status_version = page_snapshot&.version
    # With no process-wide fleet snapshot yet, the resolver below still
    # computes this exact task row directly; that is current enough for task
    # controls without forcing a fleet scan. An explicit feed failure remains
    # unavailable/degraded and disables those controls.
    @status_availability = page_snapshot&.availability || "fresh"
    @status_last_success_at = page_snapshot&.last_success_at
    @status_error = page_snapshot&.error
    @status_fresh = @status_availability == "fresh"
    @task_source = "archive" if params[:source] == "archive"
    if @task_source
      @task = Task.find!(
        project: @project, slug: params[:slug],
        snapshot: StatusBroadcaster.archive_snapshot
      )
    else
      result = Hive::Web::TaskTargetResolver.new(
        project: @project.attributes,
        slug: params[:slug],
        cached_payload: page_snapshot&.payload
      ).call
      @task = Task.new(project: @project, attributes: result.attributes)
    end
  end
end
