class Tasks::InterventionsController < Tasks::BaseController
  before_action :load_task

  def create
    dispatcher.intervene(folder: @task.folder, message: params[:message])
    redirect_to task_path(@project.name, params[:slug]), notice: "Answer recorded"
  end
end
