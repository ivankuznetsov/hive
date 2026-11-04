class Tasks::RecoveriesController < Tasks::BaseController
  def create
    receipt = @task.recover!(observation_token: params[:observation_token])
    flash_type = %w[queued running terminal].include?(receipt.status) ? :notice : :alert
    redirect_to task_path(@project.name, @task.slug, source: @task_source),
                flash: { flash_type => receipt.human_summary }
  end
end
