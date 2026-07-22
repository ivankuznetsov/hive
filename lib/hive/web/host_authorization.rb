require "uri"
require "ipaddr"
require "hive/web/environment"

module Hive
  module Web
    # Production HostAuthorization inputs for the native loopback bypass.
    # Keeping this policy in the gem lets tests drive the real Rails
    # middleware behavior instead of source-matching production.rb.
    module HostAuthorization
      module_function

      def allowed_hosts(environment: ENV)
        return unless Hive::Web::Environment.boolean(
          "HIVE_WEB_LOCAL_LOOPBACK", environment: environment
        )

        hosts = [ "localhost", IPAddr.new("127.0.0.0/8"), IPAddr.new("::1") ]
        configured_origin = Hive::Web::Environment.value(
          "HIVE_WEB_ORIGIN", environment: environment
        )
        if configured_origin
          origin_host = URI.parse(configured_origin).host
          hosts << origin_host if origin_host
        end
        hosts
      end
    end
  end
end
