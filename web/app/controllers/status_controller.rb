class StatusController < ApplicationController
  def index
    @payload = StatusBroadcaster.snapshot
    @projects = @payload.fetch("projects", [])
    @daemon_status = daemon_status
  end

  private

  # Build the daemon-status envelope in-process. StatusReport is the same
  # producer behind `hive daemon status --json`, returning the envelope as a
  # Hash — so we never reassign the process-global $stdout (which under
  # threaded Puma would capture/suppress/interleave concurrent requests'
  # output). `safe_payload` never raises on a not-running daemon.
  def daemon_status
    require "hive/daemon/status_report"
    Hive::Daemon::StatusReport.new.safe_payload
  rescue StandardError => e
    Rails.logger.warn("daemon_status probe failed: #{e.class}: #{e.message}")
    { "ok" => false, "running" => false, "message" => e.message }
  end
end
