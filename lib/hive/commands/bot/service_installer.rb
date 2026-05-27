require "cgi"
require "shellwords"
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

        def target_path
          case platform
          when :macos then File.join(@home, "Library/LaunchAgents/local.hive-bot.plist")
          when :linux then File.join(@home, ".config/systemd/user/hive-bot.service")
          end
        end

        private

        def render_systemd
          template = File.read(File.expand_path("../../../../examples/systemd/hive-bot.service", __dir__))
          # systemd .service files are POSIX-shell-ish — escape the
          # resolved binary path so whitespace, `%`, or other special
          # characters don't produce a malformed unit. No HIVE_BIN line to
          # rewrite (only the daemon's status_consumer needs that).
          escaped = Shellwords.escape(resolved_binary)
          template
            .sub(/^ExecStart=.*$/, "ExecStart=#{escaped} bot start --foreground")
            .sub(/^Environment=PATH=.*$/, build_path_line)
        end

        def render_launchd
          template = File.read(File.expand_path("../../../../examples/launchd/hive-bot.plist", __dir__))
          binary = resolved_binary
          # dirname BEFORE HTML-escaping so paths with `&`/`<`/`>` get
          # the correct directory segmentation; then escape both for
          # plist XML safety.
          binary_dir = File.dirname(binary)
          escaped_binary = CGI.escapeHTML(binary)
          escaped_binary_dir = CGI.escapeHTML(binary_dir)
          escaped_home = CGI.escapeHTML(@home)
          template
            .gsub(%r{<string>/Users/YOU/\.local/bin/hive</string>}, "<string>#{escaped_binary}</string>")
            .gsub("/Users/YOU/Library/Logs", "#{escaped_home}/Library/Logs")
            .gsub("/Users/YOU/.local/bin", escaped_binary_dir)
        end
      end
    end
  end
end
