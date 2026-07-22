class Tasks::RecoveriesController < Tasks::BaseController
  def create
    @task.recover!
    redirect_to task_path(@project.name, @task.slug),
                notice: "Recovery queued — clearing the error and re-running the stage"
  end
end
