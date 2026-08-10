class Tasks::LogsController < Tasks::BaseController
  def show
    render partial: "tasks/log", locals: { log: @task.latest_log }
  end
end
