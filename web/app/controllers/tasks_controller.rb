class TasksController < Tasks::BaseController
  def show
    questions = @task.open_questions
    @brainstorm_suggestions = questions.to_h do |question|
      [ question.ordinal, question.suggestion ]
    end
    @daemon_enabled = @project.daemon_enabled?
    builder = task_workspace_builder(
      questions: questions, daemon_enabled: @daemon_enabled
    )
    @workspace = builder.call
    @workspace_action_evidence_current = @task_source.nil? &&
                                         @workspace.dig("status", "state") == "current"
    # Bound questions are revalidated by Hive::Commands::Answer on write; the
    # workspace decision keeps their readiness independent of execution evidence.
    @answer_input_enabled = @workspace.dig("decision", "posture") == "answer" &&
                            @workspace.dig("decision", "action", "enabled") == true
    respond_to do |format|
      format.html do
        # v1 remains private compatibility state for guarded mutations and
        # bound questions. Every visible task meaning is composed from v2.
        @semantic_workspace = builder.semantic
        @publication_refresh_available = @task_source.nil? &&
                                         session[:github_token].present? &&
                                         @semantic_workspace.dig("applicability", "publication") == true &&
                                         @workspace.dig("panels", "publication", "refresh", "eligible") == true
        @media = @task.media_manifest
        @outcome_evidence = @task.outcome_evidence
        @plan_review = @task.plan_review_details
        @daemon_running = Daemon.new.running?
      end
      format.json { render json: @workspace }
    end
  end
end
