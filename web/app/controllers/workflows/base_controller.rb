module Workflows
  class BaseController < ApplicationController
    private

    def load_workflow_page(selected = nil)
      @projects = registered_projects
      @selected_project = selected || selected_project
      @workflows = @selected_project ? Workflow.for(@selected_project) : []
      @templates = Workflow.templates
    end

    def selected_project
      requested = params[:project].to_s.strip
      return find_project!(requested) unless requested.empty?
      return @projects.first if @projects.one?

      nil
    end

    def project_from_param!
      find_project!(params.require(:project).to_s)
    end

    def operation
      request.path_parameters.fetch(:operation)
    end
  end
end
