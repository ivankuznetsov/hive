module Modules
  class ChangesController < BaseController
    def create
      outcome = ModuleChange.apply!(
        operation:, token: params.require(:preview_token), consent: params[:consent],
        grant_consents: params[:grant_consents]
      )
      redirect_to modules_path(project: outcome.project.name), notice: outcome.notice
    end
  end
end
