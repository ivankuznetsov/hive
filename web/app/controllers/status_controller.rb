class StatusController < ApplicationController
  def index
    @payload = StatusBroadcaster.snapshot
    @projects = @payload.fetch("projects", [])
  end
end
