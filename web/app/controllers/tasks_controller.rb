class TasksController < Tasks::BaseController
  def show
    questions = @task.open_questions
    @daemon_enabled = @project.daemon_enabled?
    @workspace = task_workspace_builder(
      questions_count: questions.length, questions: questions, daemon_enabled: @daemon_enabled
    ).call
    @workspace_action_evidence_current = @task_source.nil? &&
                                         @workspace.dig("status", "state") == "current"
    @artifact_panel = @workspace.dig("panels", "artifacts")
    @publication_refresh_available = @task_source.nil? &&
                                     session[:github_token].present? &&
                                     @workspace.dig("panels", "publication", "refresh", "eligible") == true
    respond_to do |format|
      format.html do
        @media = @task.media_manifest
        @outcome_evidence = @task.outcome_evidence
        @log = @task.latest_log
        @daemon_running = Daemon.new.running?
      end
      format.json { render json: @workspace }
    end
  end
end
