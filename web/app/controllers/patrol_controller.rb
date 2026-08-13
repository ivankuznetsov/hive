class PatrolController < ApplicationController
  def index
    @projects = registered_projects
    requested = params[:project].to_s.strip
    @selected_project = if requested.empty?
      @projects.first
    else
      find_project!(requested)
    end
    @overview = PatrolOverview.new(@selected_project) if @selected_project
  end
end
