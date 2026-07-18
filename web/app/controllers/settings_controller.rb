class SettingsController < ApplicationController
  def show
    @default_view = default_work_view
  end

  def update
    view = params.require(:default_view).to_s
    unless ApplicationController::WORK_VIEWS.include?(view)
      raise Hive::Error, "unknown default view #{view.inspect}; choose board or grid"
    end

    cookies.signed.permanent[:hive_default_view] = {
      value: view,
      same_site: :lax,
      httponly: true
    }
    redirect_to settings_path, notice: "Default work view set to #{view.capitalize}"
  end
end
