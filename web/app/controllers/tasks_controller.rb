class TasksController < Tasks::BaseController
  before_action :load_task

  def show
    @files = @task.artifacts
    @media = @task.media_manifest
    @log = @task.latest_log
    @questions = @task.open_questions
    @daemon_enabled = @project.daemon_enabled?
    @daemon_running = daemon_running?
  end

  private

  def daemon_running?
    require "hive/daemon/status_report"
    Hive::Daemon::StatusReport.new.running_state[:running] == true
  rescue StandardError => e
    Rails.logger.warn("daemon liveness probe failed: #{e.class}: #{e.message}")
    false
  end
end
