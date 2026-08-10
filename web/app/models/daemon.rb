require "hive/bot/dispatch_request_writer"
require "hive/daemon/dispatch_request_queue"
require "hive/daemon/status_report"

class Daemon
  def running?
    Hive::Daemon::StatusReport.new.running_state[:running] == true
  rescue StandardError => e
    Rails.logger.warn("daemon liveness probe failed: #{e.class}: #{e.message}")
    false
  end

  def repair!
    request_id = Hive::Bot::DispatchRequestWriter.generate_request_id
    Hive::Bot::DispatchRequestWriter.write!(
      project: Hive::Daemon::DispatchRequestQueue::GLOBAL_MAINTENANCE_PROJECT,
      slug: "daemon-repair",
      argv: %w[hive daemon install --force],
      trigger: "web_daemon_repair",
      request_id:
    )
    request_id
  rescue ArgumentError
    raise Hive::Error, "cannot queue daemon repair on this host; run `hive daemon install --force`"
  end
end
