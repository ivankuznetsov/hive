class Tasks::BaseController < ApplicationController
  before_action :load_project
  before_action :load_task

  private

  def load_project
    @project = find_project!(params[:project])
  end

  def load_task
    page_snapshot = StatusBroadcaster.snapshot_with_version
    @status_version = page_snapshot.version
    @task = Task.find!(project: @project, slug: params[:slug], snapshot: page_snapshot.payload)
  end
end
