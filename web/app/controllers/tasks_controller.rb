class TasksController < Tasks::BaseController
  def show
    @files = @task.artifacts
    @media = @task.media_manifest
    @log = @task.latest_log
    @questions = @task.open_questions
    @daemon_enabled = @project.daemon_enabled?
    @daemon_running = Daemon.new.running?
  end

  private

  # Archive links opt into the dedicated unfiltered source. Keep the ordinary
  # page snapshot/version as the live-refresh baseline, but resolve the row
  # itself from archive status so an expired task is not misreported as a 404.
  def load_task
    return super unless params[:source] == "archive"

    page_snapshot = StatusBroadcaster.snapshot_with_version
    @status_version = page_snapshot.version
    @task = Task.find!(
      project: @project,
      slug: params[:slug],
      snapshot: StatusBroadcaster.archive_snapshot
    )
  end
end
