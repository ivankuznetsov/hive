require "time"

module Hive
  module Daemon
    # Compatibility availability publisher. It never executes provider,
    # credential, doctor, or command probes. Availability may wake a daemon
    # tick, but persisted retry deadlines remain authoritative.
    class HealthProbe
      def initialize(**_options); end

      def publish(category:, available:, observed_at: Time.now.utc)
        {
          reason: category.to_s,
          available: available == true,
          observed_at: observed_at.utc.iso8601,
          authority: "availability_only"
        }
      end
    end
  end
end
