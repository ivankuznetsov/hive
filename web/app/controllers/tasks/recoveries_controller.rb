class Tasks::RecoveriesController < Tasks::BaseController
  def create
    receipt = @task.recover!
    flash_type = %w[queued running terminal].include?(receipt.status) ? :notice : :alert
    redirect_to task_path(@project.name, @task.slug),
                flash: { flash_type => receipt.human_summary }
  end
end
