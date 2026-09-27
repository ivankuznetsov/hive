module Hive
  module RuntimeControlPlane
    # Audited long-lived launch surfaces. Increment 1 deliberately qualifies
    # none as unable to create unregistered descendants: a non-empty process
    # inventory therefore remains fail-closed until delegated custody exists.
    module LaunchCoverage
      ROWS = [
        { origin: "direct_cli", gate: "bin/hive command registration", child_safe: false },
        { origin: "attempt", gate: "detached wrapper reservation", child_safe: false },
        { origin: "daemon_child", gate: "registered bin/hive child", child_safe: false },
        { origin: "hivebox_supervisor", gate: "durable lifecycle restart gate", child_safe: false },
        { origin: "web_capture", gate: "registered bin/hive capture server", child_safe: false }
      ].map(&:freeze).freeze

      module_function

      def row(origin)
        ROWS.find { |entry| entry.fetch(:origin) == origin.to_s }
      end

      def proven_child_safe?(origin)
        row(origin)&.fetch(:child_safe) == true
      end
    end
  end
end
