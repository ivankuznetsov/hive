class Tasks::DiffsController < Tasks::BaseController
  before_action :load_task

  def show
    diff = @task.diff
    @diff = diff.content
    @diff_truncated = diff.truncated?
    render "tasks/diff"
  end
end
