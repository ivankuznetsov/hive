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

      def snapshot(installer:, config:, environment: ENV, probe: nil,
                   wait_for_running: false, attempts: 12, interval: 0.25,
                   sleeper: nil)
        state = lifecycle_state(installer)
        if wait_for_running
          state = wait_for_running_state(
            installer,
            state,
            attempts: attempts,
            interval: interval,
            sleeper: sleeper
          )
        end
        url = effective_url(config, environment: environment)
        health_probe = probe || lambda { |health_url|
          ready?(
            health_url,
            attempts: wait_for_running ? attempts : 1,
            interval: interval
          )
        }
        readiness = readiness_for(state, local_url(config), probe: health_probe)
        state.merge(
          "url" => url,
          "ready" => readiness == "ready",
          "readiness" => readiness
        )
      end

      def lifecycle_state(installer)
        observed = if installer&.respond_to?(:service_lifecycle_state)
          installer.service_lifecycle_state
        elsif installer
          installer.service_state
        else
          {}
        end
        {
          "platform" => "unsupported",
          "unit_path" => nil,
          "service_installed" => false,
          "service_enabled" => false,
          "service_running" => false,
          "service_manager_available" => false
        }.merge(observed)
      end

      # launchctl returns from `load` before the job necessarily transitions
      # to running. During mutating setup/install flows, resample the manager
      # state inside the same bounded readiness window before deciding the
      # service is inactive. Read-only `hive web status` keeps its immediate
      # one-sample behavior by leaving `wait_for_running` false.
      def wait_for_running_state(installer, state, attempts:, interval:, sleeper: nil)
        return state unless installer
        return state unless state.values_at(
          "service_manager_available", "service_installed", "service_enabled"
        ).all?
        return state if state["service_running"]

        sleeper ||= ->(duration) { sleep duration }
        (Integer(attempts) - 1).times do
          sleeper.call(interval)
          state = lifecycle_state(installer)
          break if state["service_running"]
          break unless state.values_at(
            "service_manager_available", "service_installed", "service_enabled"
          ).all?
        end
        state
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
