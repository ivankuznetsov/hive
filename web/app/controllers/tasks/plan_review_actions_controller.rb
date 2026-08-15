module Tasks
  class PlanReviewActionsController < BaseController
    def create
      result = @task.plan_review_action!(
        action: params.require(:review_action),
        review_id: params.require(:review_id),
        task_generation: params.require(:task_generation),
        policy_fingerprint: params.require(:policy_fingerprint),
        expected_artifact_digest: params.require(:expected_artifact_digest),
        target_fingerprint: params[:target_fingerprint].presence,
        answer: params[:answer], coverage: params[:coverage], level: params[:level],
        reason: params[:reason], operator: operator_label, authorized: operator_access?
      )
      state = result.fetch(:projection).record.state.tr("_", " ")
      message = result.fetch(:applied) ? "Plan review action applied" : "Plan review action already applied"
      redirect_to task_path(@project.name, @task.slug, source: @task_source),
                  notice: "#{message}; current state: #{state}."
    rescue Hive::PlanReview::StaleDecision, Hive::PlanReview::ConflictingDecision
      redirect_to task_path(@project.name, @task.slug, source: @task_source),
                  alert: "Plan review changed. Refreshed the current review; no action was applied."
    end
  end
end
