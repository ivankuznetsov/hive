class Tasks::ApprovalsController < Tasks::BaseController
  def create
    dispatcher.approve(slug: params[:slug], project: @project.name,
                       from: params[:from], to: params[:to], force: params[:force] == "1")
    redirect_to root_path, notice: "Approved #{params[:slug]}"
  end
end
