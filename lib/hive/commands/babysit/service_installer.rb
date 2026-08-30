require "hive/commands/service_installer/base"
require "hive/commands/babysit"
require "hive/paths"

module Hive
  module Commands
    class Babysit
      # Installs the babysitter as a supervised per-user foreground process.
      # Project configuration remains the mutation gate: the idle service only
      # acts on registered projects with `babysitter.enabled: true`.
      class ServiceInstaller < Hive::Commands::ServiceInstaller::Base
        class LegacyTakeover
          def initialize(hive_home:)
            @hive_home = hive_home
          end

          def pending?
            File.exist?(File.join(@hive_home, ".babysitter.pid"))
          end

          def stop!
            return true unless pending?

            Hive::Commands::Babysit.new("stop", hive_home: @hive_home, quiet: true).call
            !pending?
          end
        end

        def initialize(hive_home: Hive::Paths.state_home, **kwargs)
          super(**kwargs, legacy_takeover: LegacyTakeover.new(hive_home: hive_home))
        end

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
