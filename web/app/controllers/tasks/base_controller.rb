class Tasks::BaseController < ApplicationController
  before_action :load_project

  private

  def load_project
    @project = find_project!(params[:project])
  end

  def load_task
    @task = Task.find!(project: @project, slug: params[:slug])
  end

  def dispatcher
    Hive::Web::Dispatcher.new
  end
end
