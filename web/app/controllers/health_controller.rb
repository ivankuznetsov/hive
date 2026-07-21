require "hive/pid_file"

class HealthController < ApplicationController
  skip_before_action :require_login

  # Reads the daemon's pidfile the same way `hive daemon status` does —
  # stale files and reused PIDs don't count as alive.
  class DaemonProbe
    include Hive::PidFile

    def pid_file
      File.join(Hive::Paths.state_home, ".daemon.pid")
    end
  end

  # `/health` is web liveness (also the supervisor/installer smoke), while
  # `/health?deep=1` is the Hivebox readiness probe: the container is only
  # useful when the daemon child is running too — a crashlooping daemon
  # must turn the container unhealthy, not sit invisible behind a green
  # web tier.
  def show
    return render json: { ok: true } unless params[:deep].present?

    daemon_pid = DaemonProbe.new.read_live_pid
    if daemon_pid
      render json: { ok: true, daemon: { running: true, pid: daemon_pid } }
    else
      render json: { ok: false, daemon: { running: false } }, status: :service_unavailable
    end
  end
end
