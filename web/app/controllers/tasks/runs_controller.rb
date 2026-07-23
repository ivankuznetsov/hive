class Tasks::RunsController < Tasks::BaseController
  def create
    @task.run!(expected_action: params[:action_name], expected_stage: params[:stage])
    redirect_to task_path(@project.name, @task.slug), notice: "Queued for the daemon"
  end
end
