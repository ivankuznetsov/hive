class HealthController < ApplicationController
  skip_before_action :require_login

  def show
    render json: { ok: true }
  end
end
