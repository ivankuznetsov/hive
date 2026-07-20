require "json"
require "net/http"
require "uri"
require "hive/web/environment"
require "hive/web/loopback"

module Hive
  module Web
    # One read-only producer for the native Hive web lifecycle contract.
    # ServiceInstaller owns platform state; this component adds the effective
    # URL and an application-level /health observation without mutating the
    # unit, config, bind address, or exposure policy.
    module ServiceStatus
      module_function

      READINESS = %w[
        ready manager_unavailable not_installed disabled inactive active_not_ready invalid_url
      ].freeze

      def snapshot(installer:, config:, environment: ENV, probe: nil)
        state = if installer&.respond_to?(:service_lifecycle_state)
          installer.service_lifecycle_state
        elsif installer
          installer.service_state
        else
          {}
        end
        state = {
          "platform" => "unsupported",
          "unit_path" => nil,
          "service_installed" => false,
          "service_enabled" => false,
          "service_running" => false,
          "service_manager_available" => false
        }.merge(state)
        url = effective_url(config, environment: environment)
        readiness = readiness_for(state, local_url(config), probe: probe)
        state.merge(
          "url" => url,
          "ready" => readiness == "ready",
          "readiness" => readiness
        )
      end

      def effective_url(config, environment: ENV)
        origin = Hive::Web::Environment.value(
          "HIVE_WEB_ORIGIN", environment: environment, default: config["origin"]
        ).to_s.strip
        return origin.sub(%r{/+\z}, "") unless origin.empty?

        endpoint_url(config.fetch("bind"), config.fetch("port"))
      end

      def local_url(config)
        bind = config.fetch("bind").to_s
        bind = "127.0.0.1" if %w[0.0.0.0 ::].include?(bind)
        endpoint_url(bind, config.fetch("port"))
      end

      def endpoint_url(host, port)
        URI::HTTP.build(host: host.to_s, port: Integer(port)).to_s.sub(%r{/\z}, "")
      end

      def health_url(url)
        uri = URI.parse(url)
        uri.path = "/health"
        uri.query = nil
        uri.fragment = nil
        uri.to_s
      end

      def readiness_for(state, url, probe: nil)
        return "manager_unavailable" unless state["service_manager_available"]
        return "not_installed" unless state["service_installed"]
        return "disabled" unless state["service_enabled"]
        return "inactive" unless state["service_running"]

        check = probe || method(:ready?)
        check.call(health_url(url)) ? "ready" : "active_not_ready"
      rescue URI::InvalidURIError, KeyError
        "invalid_url"
      end

      # launchd returns from `load` before Rails necessarily accepts traffic.
      # Retry for a short bounded window, with tight per-request limits. The
      # health endpoint carries no operator state and is unauthenticated.
      def ready?(url, attempts: 12, interval: 0.25)
        uri = URI.parse(url)
        attempts.times do |attempt|
          response = Net::HTTP.start(
            uri.host, uri.port,
            use_ssl: uri.scheme == "https",
            open_timeout: 1,
            read_timeout: 1
          ) { |http| http.get(uri.request_uri, { "Host" => uri.host }) }
          body = JSON.parse(response.body) rescue {}
          return true if response.is_a?(Net::HTTPSuccess) && body["ok"] == true
          sleep interval if attempt < attempts - 1
        rescue IOError, SystemCallError, SocketError, Timeout::Error
          sleep interval if attempt < attempts - 1
        end
        false
      rescue URI::InvalidURIError
        false
      end
    end
  end
end
