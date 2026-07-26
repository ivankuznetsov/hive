module Modules
  class ChangesController < BaseController
    def create
      outcome = ModuleChange.apply!(
        operation:, token: params.require(:preview_token), consent: params[:consent],
        permission_atom_tokens: params[:permission_atom_tokens]
      )
      redirect_to modules_path(project: outcome.project.name), notice: outcome.notice
    end
  end
end
