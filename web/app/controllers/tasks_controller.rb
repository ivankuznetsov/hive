class TasksController < Tasks::BaseController
  def show
    @files = @task.artifacts
    @media = @task.media_manifest
    @outcome_evidence = @task.outcome_evidence
    @log = @task.latest_log
    @questions = @task.open_questions
    @plan_review = @task.plan_review_details
    @daemon_enabled = @project.daemon_enabled?
    @daemon_running = Daemon.new.running?
  end
end
