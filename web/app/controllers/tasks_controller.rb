class TasksController < Tasks::BaseController
  before_action :load_task

  def show
    @files = @task.artifacts
    @media = @task.media_manifest
    @log = @task.latest_log
    @questions = @task.open_questions
    @worktree_exists = @task.worktree?
    @daemon_enabled = project_daemon_enabled?
    @daemon_running = daemon_running?
  end

  private

  def project_daemon_enabled?
    Hive::Config.load(@project["path"]).dig("daemon", "enabled") != false
  rescue StandardError => e
    Rails.logger.warn("project config unreadable for #{@project["name"]}: #{e.class}: #{e.message}")
    true
  end

  def daemon_running?
    require "hive/daemon/status_report"
    Hive::Daemon::StatusReport.new.running_state[:running] == true
  rescue StandardError => e
    Rails.logger.warn("daemon liveness probe failed: #{e.class}: #{e.message}")
    false
  end
end
