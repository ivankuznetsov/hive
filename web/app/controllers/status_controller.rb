class StatusController < ApplicationController
  def index
    @payload = StatusBroadcaster.snapshot
    @projects = @payload.fetch("projects", [])
    @daemon_status = daemon_status
  end

  private

  # Build the daemon-status envelope in-process. `#status_payload` returns the
  # same hash `hive daemon status --json` prints, but as a return value — so we
  # never reassign the process-global $stdout (which under threaded Puma would
  # capture/suppress/interleave concurrent requests' output). It also never
  # raises on a not-running daemon.
  def daemon_status
    require "hive/commands/daemon"
    Hive::Commands::Daemon.new("status", json: true).status_payload
  rescue StandardError => e
    Rails.logger.warn("daemon_status probe failed: #{e.class}: #{e.message}")
    { "ok" => false, "running" => false, "message" => e.message }
  end
end
