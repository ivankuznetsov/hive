class WorkflowsController < Workflows::BaseController
  def index
    load_workflow_page
  end

  def create
    project = project_from_param!
    result = Workflow.scaffold!(
      project:,
      id: params.require(:id),
      template: params[:template].presence || Hive::Commands::Workflow::DEFAULT_TEMPLATE
    )
    redirect_to workflows_path(project: project.name),
                notice: "Created #{result.fetch('id')} for #{project.name}."
  end
end
