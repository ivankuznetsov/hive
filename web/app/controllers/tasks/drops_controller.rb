class Tasks::DropsController < Tasks::BaseController
  def create
    payload = @task.drop!(from: params[:from])
    notice = "Dropped #{@task.slug}"
    notice += " — note: its draft PR could not be closed" if payload["pr_closed"] == false
    redirect_to root_path, notice:
  end
end
