require "hive/commands/service_installer/base"

module Hive
  module Commands
    class Bot
      # Per-user autostart installer for the Telegram bot. Inherits the
      # platform-agnostic mechanics (drift/backup, atomic write, shim-PATH
      # detection, enable/load orchestration) from the shared base and
      # supplies only the bot's identity and rendered unit/plist bodies.
      #
      # Differs from the daemon installer in three ways that matter for the
      # templates: the bot loads its token from ~/.config/hive/.env itself
      # via Hive::EnvFile.load! (so no inline HIVE_TELEGRAM_BOT_TOKEN and no
      # HIVE_BIN line), and it has no in-flight child drain (so no
      # TimeoutStopSec=900 / KillMode=mixed and no upgrade-restart warning).
      class ServiceInstaller < Hive::Commands::ServiceInstaller::Base
        def service_name
          "hive-bot"
        end

        def cli_label
          "bot"
        end

        def service_noun
          "bot service"
        end

        def unit_noun
          "bot unit"
        end

        private

        # No HIVE_BIN line in the bot unit (only the daemon's status_consumer
        # needs that) — the shared renderer's HIVE_BIN substitution is a no-op.
        def render_systemd
          render_systemd_from(
            File.expand_path("../../../../examples/systemd/hive-bot.service", __dir__),
            "bot start --foreground"
          )
        end

        def render_launchd
          render_launchd_from(File.expand_path("../../../../examples/launchd/hive-bot.plist", __dir__))
        end
      end
    end
  end
end
