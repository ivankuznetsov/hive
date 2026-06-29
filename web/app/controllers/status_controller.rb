require "json"
require "stringio"

class StatusController < ApplicationController
  def index
    @payload = StatusBroadcaster.snapshot
    @projects = @payload.fetch("projects", [])
    @daemon_status = daemon_status
  end

  private

  def daemon_status
    require "hive/commands/daemon"
    out = StringIO.new
    old_stdout = $stdout
    $stdout = out
    begin
      Hive::Commands::Daemon.new("status", json: true).call
    rescue Hive::Error
      # `status --json` intentionally exits non-zero when the daemon is not
      # running, but it still prints the useful envelope first.
    ensure
      $stdout = old_stdout
    end
    JSON.parse(out.string)
  rescue StandardError => e
    { "ok" => false, "running" => false, "message" => e.message }
  end
end
