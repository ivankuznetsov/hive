class Tasks::WorkspacesController < Tasks::BaseController
  def show
    render json: task_workspace_builder.semantic
  end
end
