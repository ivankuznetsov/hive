class StatusViewPreferencesController < ApplicationController
  def create
    view = params[:view].to_s.presence_in(StatusController::VIEWS)
    raise ActionController::BadRequest, "invalid status view" unless view

    cookies.permanent.signed[StatusController::VIEW_COOKIE] = view
    redirect_to destination_for(view), status: :see_other
  end

  private

  def destination_for(view)
    route = view == "board" ? :board_path : :grid_path
    public_send(route, project: params[:project].to_s.presence)
  end
end
