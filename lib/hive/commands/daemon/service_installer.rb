require "cgi"
require "shellwords"
require "hive/commands/service_installer/base"

module Hive
  module Commands
    class Daemon
      class ServiceInstaller < Hive::Commands::ServiceInstaller::Base
        def service_name
          "hive-daemon"
        end

        def cli_label
          "daemon"
        end

        def service_noun
          "daemon service"
        end

        def unit_noun
          "daemon unit"
        end

        def target_path
          case platform
          when :macos then File.join(@home, "Library/LaunchAgents/local.hive-daemon.plist")
          when :linux then File.join(@home, ".config/systemd/user/hive-daemon.service")
          end
        end

        # Surfaced before the blocking force-upgrade restart so operators
        # know it can hang while in-flight children drain under the unit's
        # TimeoutStopSec=900.
        def upgrade_restart_warning
          "restarting hive-daemon; if the running daemon is mid-tick with " \
            "active children, this can block up to TimeoutStopSec (900s by " \
            "default) before returning"
        end

        private

        def render_systemd
          template = File.read(File.expand_path("../../../../examples/systemd/hive-daemon.service", __dir__))
          # systemd .service files are POSIX-shell-ish — escape the
          # resolved binary path so whitespace, `%`, or other special
          # characters don't produce a malformed unit.
          escaped = Shellwords.escape(resolved_binary)
          template
            .sub(/^ExecStart=.*$/, "ExecStart=#{escaped} daemon start")
            .sub(/^Environment=HIVE_BIN=.*$/, "Environment=HIVE_BIN=#{escaped}")
            .sub(/^Environment=PATH=.*$/, build_path_line)
        end

        def render_launchd
          template = File.read(File.expand_path("../../../../examples/launchd/hive-daemon.plist", __dir__))
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
