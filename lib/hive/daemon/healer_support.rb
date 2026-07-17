module Hive
  module Daemon
    # Marker evidence helpers only. Marker mutation, requeueing, retry keys,
    # counters, and dispatch helpers were removed with the coordinator cutover.
    module HealerSupport
      def marker_attrs_for(row)
        return row.marker_attrs if row.respond_to?(:marker_attrs) && row.marker_attrs.is_a?(Hash)

        {}
      end

      def marker_reason(row) = marker_attrs_for(row)["reason"].to_s
    end
  end
end
