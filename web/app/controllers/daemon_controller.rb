class DaemonController < ApplicationController
  def repair
    request_id = Hive::Web::Dispatcher.new.repair_daemon
    redirect_to root_path, notice: "Daemon repair queued (#{request_id})"
  end
end
