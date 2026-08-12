class TasksController < Tasks::BaseController
  def show
    @questions = @task.open_questions
    @daemon_enabled = @project.daemon_enabled?
    @workspace = task_workspace_builder(
      questions_count: @questions.length, daemon_enabled: @daemon_enabled
    ).call
    @artifact_panel = @workspace.dig("panels", "artifacts")
    @files = @artifact_panel.fetch("records").filter_map do |record|
      [ record.fetch("name"), record["content"] ] unless record["binary"]
    end
    respond_to do |format|
      format.html do
        @media = @task.media_manifest
        @log = @task.latest_log
        @daemon_running = Daemon.new.running?
      end
      format.json { render json: @workspace }
    end
  end
end
