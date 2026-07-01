module Hive
  module Web
    # Single source of truth for "is this address the loopback interface?".
    # Shared by the CLI bind-policy check (`Commands::Web#loopback_bind?`) and
    # the Rails loopback-peer bypass (`ApplicationController#local_loopback_request?`)
    # so the two ad-hoc string checks can't drift apart.
    module Loopback
      module_function

      # True when `value` names the loopback interface: the literal
      # "localhost", the IPv6 loopback "::1", or any IPv4 127.0.0.0/8 address.
      def address?(value)
        v = value.to_s.downcase
        return true if v == "localhost" || v == "::1"
        return false unless v.match?(/\A\d+\.\d+\.\d+\.\d+\z/)

        v.split(".").first == "127"
      end
    end
  end
end
