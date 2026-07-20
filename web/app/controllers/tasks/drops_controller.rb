class Tasks::DropsController < Tasks::BaseController
  def create
    payload = dispatcher.drop(slug: params[:slug], project: @project["name"], from: params[:from])
    notice = "Dropped #{params[:slug]}"
    notice += " — note: its draft PR could not be closed" if payload["pr_closed"] == false
    redirect_to root_path, notice:
  end
end
