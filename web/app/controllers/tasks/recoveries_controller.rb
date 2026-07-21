class Tasks::RecoveriesController < Tasks::BaseController
  before_action :load_task

  def create
    dispatcher.recover(slug: params[:slug], project: @project.name,
                       stage: @task["stage"], marker: @task["marker"], attrs: @task["attrs"],
                       workflow: @task["workflow"])
    redirect_to task_path(@project.name, params[:slug]),
                notice: "Recovery queued — clearing the error and re-running the stage"
  end
end
