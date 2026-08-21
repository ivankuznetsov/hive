class PatrolController < ApplicationController
  def index
    observed = StatusBroadcaster.snapshot
    by_name = Array(observed["projects"]).to_h { |project| [ project["name"], project ] }
    @projects = registered_projects.map do |registered|
      # Registry identity/path/config remains authoritative; the status row
      # contributes only observed tasks and the common Patrol projection.
      Project.new(by_name.fetch(registered.name, {}).merge(registered.attributes))
    end
    requested = params[:project].to_s.strip
    @selected_project = if requested.empty?
      @projects.first
    else
      find_project!(requested)
    end
    @overview = PatrolOverview.new(@selected_project) if @selected_project
  end
end
