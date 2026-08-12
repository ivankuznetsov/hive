class TasksController < Tasks::BaseController
  def show
    @artifact_panel = @task.artifact_panel
    @files = @artifact_panel.fetch("records").filter_map do |record|
      [ record.fetch("name"), record["content"] ] unless record["binary"]
    end
    @media = @task.media_manifest
    @log = @task.latest_log
    @questions = @task.open_questions
    @daemon_enabled = @project.daemon_enabled?
    @daemon_running = Daemon.new.running?
  end
end
