require "hive/daily_digest/materiality"

module Hive
  module DailyDigest
    # Named facade for first-class source gaps. Keeping construction centralized
    # preserves stable identities and bounded/redacted reasons across sources.
    module Gap
      module_function

      def build(**attributes)
        Materiality.build_gap(**attributes)
      end
    end
  end
end
