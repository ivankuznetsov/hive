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
          end
        end

        private

        def render_systemd
          template = File.read(File.expand_path("../../../../examples/systemd/hive-web.service", __dir__))
          escaped = Shellwords.escape(resolved_binary)
          template
            .sub(/^ExecStart=.*$/, "ExecStart=#{escaped} web")
            .sub(/^Environment=HIVE_BIN=.*$/, "Environment=HIVE_BIN=#{escaped}")
            .sub(/^Environment=PATH=.*$/, build_path_line)
        end

        def render_launchd
          template = File.read(File.expand_path("../../../../examples/launchd/hive-web.plist", __dir__))
          binary = resolved_binary
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
