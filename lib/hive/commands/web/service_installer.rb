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
