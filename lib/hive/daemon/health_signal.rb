require "digest"
require "json"

module Hive
  module Daemon
    # Stable fingerprint for externally supplied availability observations.
    # It owns no fallback timer and cannot authorize or schedule a retry.
    module HealthSignal
      module_function

      def fingerprint(category:, available: nil, source: nil, observed_version: nil, **_ignored)
        ::Digest::SHA256.hexdigest(JSON.generate([
          category.to_s, available == true, source.to_s, observed_version.to_s
        ]))
      end
    end
  end
end
