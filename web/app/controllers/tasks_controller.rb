class TasksController < Tasks::BaseController
  def show
    @files = @task.artifacts
    @media = @task.media_manifest
    @log = @task.latest_log
    @questions = @task.open_questions
    @daemon_enabled = @project.daemon_enabled?
    @daemon_running = Daemon.new.running?
  end
end
