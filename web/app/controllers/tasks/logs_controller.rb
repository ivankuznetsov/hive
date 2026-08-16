class Tasks::LogsController < Tasks::BaseController
  def show
    log = if params[:reference_sha256].present?
      semantic = task_workspace_builder.semantic
      reference = semantic.dig("diagnostic", "log", "reference")
      if exact_reference_digest?(reference, params[:reference_sha256])
        @task.correlated_log(reference)
      end
    else
      @task.latest_log
    end
    render partial: "tasks/log", locals: {
      log: log, project: @project, task: @task
    }
  end

  private

  def exact_reference_digest?(reference, requested)
    actual = reference.is_a?(Hash) ? reference["sha256"].to_s : ""
    candidate = requested.to_s
    actual.match?(/\A[0-9a-f]{64}\z/) && candidate.bytesize == actual.bytesize &&
      ActiveSupport::SecurityUtils.secure_compare(candidate, actual)
  end
end
