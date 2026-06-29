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
          idx = strings.index("exec \"$0\" \"$@\"") || strings.index { |value| value.end_with?("/hive") || File.basename(value) == "hive" }
          return strings[idx + 1] if idx && strings[idx + 1]

          strings.find { |value| File.basename(value) == "hive" }
        rescue REXML::ParseException, SystemCallError
          nil
        end

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
