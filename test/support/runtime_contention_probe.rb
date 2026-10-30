# Test-only subprocess synchronization. All runtime operations still use their
# real adapters and locks. Events travel on private pipes, never CLI output.
require "hive"
require "hive/runtime_control_plane/command_registration"
require "hive/commands/status"
require "hive/runtime_control_plane/task_lease_repository"

module RuntimeContentionProbe
  EVENTS = IO.for_fd(Integer(ENV.fetch("CONTENTION_EVENTS_FD")), "w")
  CONTROL = IO.for_fd(Integer(ENV.fetch("CONTENTION_CONTROL_FD")), "r")
  EVENTS.sync = true

  def self.event(value) = EVENTS.puts(value)
  def self.pause(value)
    event(value)
    raise "fixture control closed" unless CONTROL.read(1) == "1"
  end

  module Registry
    def reserve!(**options)
      Thread.current[:contention_phase] = "reserve"
      super
    ensure
      Thread.current[:contention_phase] = nil
    end
  end

  module Database
    private

    def runtime_connection(**options)
      super.tap do |database|
        database.synchronize do |raw|
          raw.trace do |sql|
            RuntimeContentionProbe.event("reserve_begin") if
              Thread.current[:contention_phase] == "reserve" && sql.start_with?("BEGIN")
          end
        end
      end
    end
  end

  module Registration
    def start!(**options)
      super.tap do |registration|
        if ENV["CONTENTION_PHASE"] == "reader"
          # Allow a new exclusive-mode WAL owner, which conflicts with reads.
          # Registration is already durable; the reader still uses Database#read.
          registration.disconnect
          RuntimeContentionProbe.pause("registered")
        end
      end
    end
  end

  module Leases
    def active_leases(**options)
      RuntimeContentionProbe.event("lease_scan")
      super
    end
  end

  module Status
    def do_call
      super.tap do
        RuntimeContentionProbe.pause("output") if ENV["CONTENTION_PHASE"] == "cleanup"
      end
    end
  end

  module Budget
    def retry_busy
      RuntimeContentionProbe.event("busy") unless @probe_seen_busy
      @probe_seen_busy = true
      super
    end

    def close
      RuntimeContentionProbe.event("waited:#{waited}")
      super
    end
  end
end

Hive::RuntimeControlPlane::ProcessRegistry.prepend(RuntimeContentionProbe::Registry)
Hive::RuntimeControlPlane::Database.prepend(RuntimeContentionProbe::Database)
Hive::RuntimeControlPlane::CommandRegistration.singleton_class.prepend(RuntimeContentionProbe::Registration)
Hive::RuntimeControlPlane::ContentionBudget.prepend(RuntimeContentionProbe::Budget)
Hive::RuntimeControlPlane::TaskLeaseRepository.prepend(RuntimeContentionProbe::Leases)
Hive::Commands::Status.prepend(RuntimeContentionProbe::Status)
