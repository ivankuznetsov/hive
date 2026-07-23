class Tasks::DiffsController < Tasks::BaseController
  def show
    diff = @task.diff
    @diff = diff.content
    @diff_truncated = diff.truncated?
    render "tasks/diff"
  end
end
