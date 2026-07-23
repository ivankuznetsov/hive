class Tasks::InterventionsController < Tasks::BaseController
  def create
    @task.intervene!(params[:message])
    redirect_to task_path(@project.name, @task.slug), notice: "Answer recorded"
  end
end
