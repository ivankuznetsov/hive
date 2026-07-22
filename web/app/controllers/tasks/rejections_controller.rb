class Tasks::RejectionsController < Tasks::BaseController
  def create
    @task.reject!(from: params[:from], to: params[:to])
    redirect_to root_path, notice: "Sent #{@task.slug} back a stage"
  end
end
