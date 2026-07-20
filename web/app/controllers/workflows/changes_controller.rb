module Workflows
  class ChangesController < BaseController
    def create
      outcome = WorkflowChange.apply!(
        operation:,
        token: params.require(:preview_token),
        consent: params[:consent],
        allow_escalation: params[:allow_escalation]
      )
      options = { notice: outcome.notice }
      options[:alert] = outcome.alert if outcome.alert
      redirect_to workflows_path(project: outcome.project.name), **options
    end
  end
end
