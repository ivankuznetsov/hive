class Tasks::LogsController < Tasks::BaseController
  before_action :load_task

  def show
    render partial: "tasks/log", locals: { log: @task.latest_log }
  end
end
