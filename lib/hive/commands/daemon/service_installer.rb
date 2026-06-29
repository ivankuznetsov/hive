require "cgi"
require "shellwords"
require "rexml/document"
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

        def installed_exec_binary
          return nil unless target_path && File.file?(target_path)

          case platform
          when :linux then installed_systemd_exec_binary
          when :macos then installed_launchd_exec_binary
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

        def installed_systemd_exec_binary
          line = File.readlines(target_path).find { |candidate| candidate.start_with?("ExecStart=") }
          return nil unless line

          Shellwords.split(line.sub(/\AExecStart=/, "").strip).first
        rescue ArgumentError
          nil
        end

        def installed_launchd_exec_binary
          doc = REXML::Document.new(File.read(target_path))
          strings = []
          doc.elements.each("//array/string") { |el| strings << el.text.to_s }
          # ProgramArguments wraps the real invocation in a /bin/sh precheck:
          #   /bin/sh -c '[ -x "$0" ] || exit 0; exec "$0" "$@"' <hive> <subcmd...>
          # The `exec "$0" "$@"` marker is embedded INSIDE the `-c` script
          # string, so it is never an exact array element — and the element
          # after the script is the hive binary itself ($0), not a subcommand.
          # Return the `$0` slot directly: the array element that is the hive
          # binary, not the element following any marker.
          strings.find { |value| File.basename(value) == "hive" || value.end_with?("/hive") }
        rescue REXML::ParseException, SystemCallError
          nil
        end

        def render_systemd
          render_systemd_from(
            File.expand_path("../../../../examples/systemd/hive-daemon.service", __dir__),
            "daemon start"
          )
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
