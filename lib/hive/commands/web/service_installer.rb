require "hive/commands/service_installer/base"
require "hive/config"
require "hive/web/app_bundle"
require "hive/web/environment"

module Hive
  module Commands
    class Web
      class ServiceInstaller < Hive::Commands::ServiceInstaller::Base
        def initialize(environment: ENV, config: nil, **kwargs)
          @web_environment = environment
          @web_config = config || Hive::Config.load_global_web
          super(**kwargs)
        end

        def service_name
          "hive-web"
        end

        def cli_label
          "web"
        end

        def service_noun
          "web service"
        end

        def unit_noun
          "web unit"
        end

        def restart!
          ok = case envelope_platform
          when "linux"
            @runner.call(%w[systemctl --user daemon-reload]) &&
              @runner.call([ "systemctl", "--user", "restart", service_name ])
          when "macos"
            @runner.call([ "launchctl", "unload", target_path ]) &&
              @runner.call([ "launchctl", "load", target_path ])
          else
            false
          end
          raise Hive::Error, "hive web: could not restart managed web service" unless ok

          @messages << "restarted running web service to load the refreshed application bundle"
          true
        end

        private

        def render_systemd
          rendered = render_systemd_from(
            File.expand_path("../../../../examples/systemd/hive-web.service", __dir__),
            "web"
          )
          lines = resolved_web_environment.map do |name, value|
            "Environment=#{name}=#{Shellwords.escape(value)}"
          end
          rendered.sub(/^Environment=HIVE_BIN=.*$/) { |line| ([ line ] + lines).join("\n") }
        end

        def render_launchd
          rendered = render_launchd_from(File.expand_path("../../../../examples/launchd/hive-web.plist", __dir__))
          entries = resolved_web_environment.map do |name, value|
            "    <key>#{CGI.escapeHTML(name)}</key>\n    <string>#{CGI.escapeHTML(value)}</string>"
          end.join("\n")
          rendered.sub("    <key>HIVE_BIN</key>", "#{entries}\n    <key>HIVE_BIN</key>")
        end

        def resolved_web_environment
          Hive::Web::Environment.resolved_for_service(
            config: @web_config,
            environment: @web_environment,
            managed_app_dir: Hive::Web::AppBundle.app_dir
          )
        end
      end
    end
  end
end
