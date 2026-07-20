class Tasks::RunsController < Tasks::BaseController
  def create
    dispatcher.assert_dispatchable!(params[:action_name])
    dispatcher.dispatch(slug: params[:slug], project: @project["name"],
                        action: params[:action_name], stage: params[:stage])
    redirect_to task_path(@project["name"], params[:slug]), notice: "Queued for the daemon"
  end
end
