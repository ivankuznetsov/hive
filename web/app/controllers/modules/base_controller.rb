module Modules
  class BaseController < ApplicationController
    private

    def load_module_page(selected = nil)
      @projects = registered_projects
      @selected_project = selected || selected_project
      @show_history = params[:history] == "1"
      @modules = @selected_project ? HiveModule.for(@selected_project, include_history: @show_history) : []
    end

    def selected_project
      requested = params[:project].to_s.strip
      return find_project!(requested) unless requested.empty?
      return @projects.first if @projects.one?
      nil
    end

    def project_from_param! = find_project!(params.require(:project).to_s)
    def operation = request.path_parameters.fetch(:operation)

    def choices
      {
        "settings" => choice_lines(params[:settings]),
        "hooks" => choice_lines(params[:hooks]),
        "grants" => choice_lines(params[:grants])
      }
    end

    def choice_lines(value)
      value.to_s.lines.map(&:strip).reject { |line| line.empty? || line.start_with?("#") }
    end
  end
end
