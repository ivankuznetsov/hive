class DaemonRepairsController < ApplicationController
  def create
    request_id = Daemon.new.repair!
    redirect_to root_path, notice: "Daemon repair queued (#{request_id})"
  end
end
