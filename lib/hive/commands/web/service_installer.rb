require "cgi"
require "shellwords"
require "hive/commands/service_installer/base"

module Hive
  module Commands
    class Web
      class ServiceInstaller < Hive::Commands::ServiceInstaller::Base
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

        def target_path
          case platform
          when :macos then File.join(@home, "Library/LaunchAgents/local.hive-web.plist")
          when :linux then File.join(@home, ".config/systemd/user/hive-web.service")
          else
            # An unrecognized platform has no autostart unit path; returning nil
            # would silently flow into systemctl/launchctl argv. Fail loudly so
            # `:other` is not a silently-representable illegal state.
            raise Hive::InvalidTaskPath,
                  "hive web: autostart is not supported on this platform (#{platform})"
          end
        end

        private

        def render_systemd
          render_systemd_from(
            File.expand_path("../../../../examples/systemd/hive-web.service", __dir__),
            "web"
          )
        end

        def render_launchd
          render_launchd_from(File.expand_path("../../../../examples/launchd/hive-web.plist", __dir__))
        end
      end
    end
  end
end
