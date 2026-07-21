class Tasks::RejectionsController < Tasks::BaseController
  def create
    dispatcher.reject(slug: params[:slug], project: @project.name,
                      from: params[:from], to: params[:to])
    redirect_to root_path, notice: "Sent #{params[:slug]} back a stage"
  end
end
