class Tasks::InterventionsController < Tasks::BaseController
  def create
    @task.intervene!(params[:message], binding: params[:binding])
    redirect_to task_path(@project.name, @task.slug, source: @task_source), notice: "Answer recorded"
  end
end
