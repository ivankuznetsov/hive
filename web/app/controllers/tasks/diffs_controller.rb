class Tasks::DiffsController < Tasks::BaseController
  def show
    @diff_result = @task.diff
    respond_to do |format|
      format.html { render "tasks/diff", status: @diff_result.http_status }
      format.json { render json: @diff_result.to_h, status: @diff_result.http_status }
    end
  end
end
