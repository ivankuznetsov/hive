module Workflows
  class PreviewsController < BaseController
    def create
      @workflow_change = WorkflowChange.preview!(
        operation:,
        project: project_from_param!,
        **preview_identity
      )
      if @workflow_change.already_current?
        return redirect_to workflows_path(project: @workflow_change.project.name),
                           notice: "#{@workflow_change.fetch('name')} is already current."
      end

      load_workflow_page(@workflow_change.project)
      render "workflows/index", formats: :html, content_type: "text/html"
    end

    private

    def preview_identity
      return { source: params.require(:source) } if operation == "install"

      { name: params.require(:name) }
    end
  end
end
