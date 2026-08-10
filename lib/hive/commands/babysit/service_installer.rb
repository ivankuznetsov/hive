require "hive/commands/service_installer/base"

module Hive
  module Commands
    class Babysit
      # Installs the babysitter as a supervised per-user foreground process.
      # Project configuration remains the mutation gate: the idle service only
      # acts on registered projects with `babysitter.enabled: true`.
      class ServiceInstaller < Hive::Commands::ServiceInstaller::Base
        def service_name
          "hive-babysitter"
        end

        def cli_label
          "babysit"
        end

        def service_noun
          "babysitter service"
        end

        def unit_noun
          "babysitter unit"
        end

        private

        def upgrade_restart_warning
          "restarting hive-babysitter; if a PR repair is in flight this can block up to " \
            "TimeoutStopSec (610s) before returning"
        end

        def render_systemd
          rendered = render_systemd_from(
            File.expand_path("../../../../examples/systemd/hive-babysitter.service", __dir__),
            "babysit start"
          )
          render_systemd_runtime_environment(rendered)
        end

        def render_launchd
          rendered = render_launchd_from(
            File.expand_path("../../../../examples/launchd/hive-babysitter.plist", __dir__)
          )
          render_launchd_runtime_environment(rendered)
        end
      end
    end
  end
end
