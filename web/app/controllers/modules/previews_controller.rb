module Modules
  class PreviewsController < BaseController
    def create
      project = project_from_param!
      @module_change = ModuleChange.preview!(
        operation:, project:, source: params[:source], name: params[:name], choices:
      )
      load_module_page(project)
      render "modules/index", formats: :html, content_type: "text/html"
    end
  end
end
