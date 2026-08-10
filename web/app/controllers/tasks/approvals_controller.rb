class Tasks::ApprovalsController < Tasks::BaseController
  def create
    @task.approve!(from: params[:from], to: params[:to], force: params[:force] == "1")
    redirect_to root_path, notice: "Approved #{@task.slug}"
  end
end
