class Tasks::LogsController < Tasks::BaseController
  def show
    render partial: "tasks/log", locals: {
      log: @task.latest_log, project: @project, task: @task
    }
  end
end
