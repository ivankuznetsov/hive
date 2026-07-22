class Tasks::BaseController < ApplicationController
  before_action :load_project
  before_action :load_task

  private

  def load_project
    @project = find_project!(params[:project])
  end

  def load_task
    @task = Task.find!(project: @project, slug: params[:slug])
  end
end
