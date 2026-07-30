require "shellwords"
require "rexml/document"
require "hive/commands/service_installer/base"

module Hive
  module Commands
    class Daemon
      class ServiceInstaller < Hive::Commands::ServiceInstaller::Base
        PERSISTED_RUNTIME_ENV = %w[
          HIVE_HOME XDG_CACHE_HOME XDG_CONFIG_HOME XDG_DATA_HOME
          XDG_STATE_HOME
        ].freeze

        def initialize(environment: ENV, **kwargs)
          @runtime_environment = environment
          super(**kwargs)
        end

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
          # The `-c` script is the element after "-c"; the next element is the
          # hive binary itself ($0). Identify the $0 slot POSITIONALLY rather
          # than by a `basename == "hive"` check — a binary resolved as `hv`, a
          # shim, or a renamed path is still the $0 slot, but the name check
          # would miss it and falsely report binary_drift "unparseable".
          dash_c = strings.index("-c")
          return strings[dash_c + 2] if dash_c && strings.length > dash_c + 2

          # Fallback for a plist without the /bin/sh wrapper: accept the hive
          # binary by basename or trailing path segment.
          strings.find { |value| File.basename(value) == "hive" || value.end_with?("/hive") }
        rescue REXML::ParseException, SystemCallError
          nil
        end

        def render_systemd
          rendered = render_systemd_from(
            File.expand_path("../../../../examples/systemd/hive-daemon.service", __dir__),
            "daemon start"
          )
          lines = resolved_runtime_environment.map do |name, value|
            "Environment=#{name}=#{Shellwords.escape(value)}"
          end
          rendered.sub(/^Environment=HIVE_BIN=.*$/) do |line|
            ([ line ] + lines).join("\n")
          end
        end

        def render_launchd
          rendered = render_launchd_from(
            File.expand_path(
              "../../../../examples/launchd/hive-daemon.plist", __dir__
            )
          )
          entries = resolved_runtime_environment.map do |name, value|
            "    <key>#{CGI.escapeHTML(name)}</key>\n" \
              "    <string>#{CGI.escapeHTML(value)}</string>"
          end.join("\n")
          rendered.sub(
            "    <key>PATH</key>",
            "#{entries}\n    <key>PATH</key>"
          )
        end

        def resolved_runtime_environment
          PERSISTED_RUNTIME_ENV.each_with_object({}) do |name, result|
            value = @runtime_environment[name].to_s
            next if value.empty?

            unsafe = value.each_byte.any? do |byte|
              byte < 0x20 || byte == 0x7f
            end
            absolute = File.absolute_path(value) == value
            if unsafe || !absolute
              raise Hive::ConfigError,
                    "#{name} must be an absolute path without control bytes"
            end

            result[name] = File.expand_path(value)
          rescue ArgumentError
            raise Hive::ConfigError,
                  "#{name} must be an absolute path without control bytes"
          end
        end
      end
    end
  end
end
