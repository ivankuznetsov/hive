class TasksController < Tasks::BaseController
  def show
    questions = @task.open_questions
    @daemon_enabled = @project.daemon_enabled?
    @workspace = task_workspace_builder(
      questions: questions, daemon_enabled: @daemon_enabled
    ).call
    @workspace_action_evidence_current = @task_source.nil? &&
                                         @workspace.dig("status", "state") == "current"
    # Bound questions are revalidated by Hive::Commands::Answer on write; the
    # workspace decision keeps their readiness independent of execution evidence.
    @answer_input_enabled = @workspace.dig("decision", "posture") == "answer" &&
                            @workspace.dig("decision", "action", "enabled") == true
    @artifact_panel = @workspace.dig("panels", "artifacts")
    @publication_refresh_available = @task_source.nil? &&
                                     session[:github_token].present? &&
                                     @workspace.dig("panels", "publication", "refresh", "eligible") == true
    respond_to do |format|
      format.html do
        @media = @task.media_manifest
        @outcome_evidence = @task.outcome_evidence
        @log = @task.latest_log
        @plan_review = @task.plan_review_details
        @daemon_running = Daemon.new.running?
      end
      format.json { render json: @workspace }
    end
  end
end
