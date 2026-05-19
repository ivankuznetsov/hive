require "cgi"
require "fileutils"
require "rbconfig"
require "shellwords"

module Hive
  module Commands
    class Daemon
      class ServiceInstaller
        attr_reader :messages

        def initialize(host_os: RbConfig::CONFIG["host_os"], home: nil, binary_path: nil, runner: nil,
                       systemctl_available: nil)
          @host_os = host_os
          # Anchor on the real user home for launchd/systemd paths —
          # HIVE_HOME is a config/test override that does not apply
          # here (launchd literally reads `~/Library/...`). We honor
          # `ENV["HOME"]` over `Dir.home` so test sandboxes that swap
          # HOME stay hermetic.
          @home = File.expand_path(home || ENV["HOME"] || Dir.home)
          @binary_path = binary_path
          @runner = runner || ->(argv) { system(*argv) }
          @systemctl_available = systemctl_available
          @messages = []
        end

        def install!(autostart:)
          case platform
          when :macos then install_macos!(autostart: autostart)
          when :linux then install_linux!(autostart: autostart)
          when :unsupported_host
            @messages << "daemon autostart not supported on this platform; run `hive daemon start` manually."
            :unsupported
          end
        end

        def target_path
          case platform
          when :macos then File.join(@home, "Library/LaunchAgents/local.hive-daemon.plist")
          when :linux then File.join(@home, ".config/systemd/user/hive-daemon.service")
          end
        end

        private

        def install_macos!(autostart:)
          path = target_path
          write_if_safe(path, render_launchd)
          if autostart
            ok = @runner.call([ "launchctl", "load", path ])
            unless ok
              @messages << "launchctl load failed for #{path}; run `launchctl load #{path}` manually"
              return :failed
            end
          end
          :ok
        end

        def install_linux!(autostart:)
          path = target_path
          write_if_safe(path, render_systemd)
          if autostart
            if systemctl_available?
              ok_reload = @runner.call(%w[systemctl --user daemon-reload])
              ok_enable = @runner.call(%w[systemctl --user enable --now hive-daemon])
              unless ok_reload && ok_enable
                @messages << "systemctl --user enable failed; run `systemctl --user enable --now hive-daemon` manually"
                return :failed
              end
            else
              @messages << "systemd not detected; enable systemd in WSL or run `hive daemon start` manually."
            end
          end
          :ok
        end

        def write_if_safe(path, content)
          if File.exist?(path)
            existing = File.read(path)
            return :unchanged if existing == content

            @messages << "daemon service already exists at #{path}; leaving user-customized file untouched."
            return :drifted
          end

          FileUtils.mkdir_p(File.dirname(path))
          File.write(path, content)
          :written
        end

        def render_systemd
          template = File.read(File.expand_path("../../../../examples/systemd/hive-daemon.service", __dir__))
          # systemd .service files are POSIX-shell-ish — escape the
          # resolved binary path so whitespace, `%`, or other special
          # characters don't produce a malformed unit.
          escaped = Shellwords.escape(resolved_binary)
          template.sub(/^ExecStart=.*$/, "ExecStart=#{escaped} daemon start")
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

        def resolved_binary
          path = @binary_path || which("hive") || File.expand_path("../../../../bin/hive", __dir__)
          File.exist?(path) ? File.realpath(path) : path
        end

        def which(name)
          ENV["PATH"].to_s.split(File::PATH_SEPARATOR).each do |dir|
            path = File.join(dir, name)
            return path if File.file?(path) && File.executable?(path)
          end
          nil
        end

        def platform
          case @host_os
          when /darwin/i then :macos
          when /linux/i then :linux
          else :unsupported_host
          end
        end

        # Differentiate "systemctl missing" (ENOENT — Tier-3 host)
        # from "systemctl exists but rejected the call" (working-
        # but-disabled systemd-user). Treat any non-ENOENT failure as
        # available so we surface the real systemctl error to the
        # user on the next call.
        def systemctl_available?
          return @systemctl_available unless @systemctl_available.nil?

          system("systemctl", "--user", "--version", out: File::NULL, err: File::NULL)
        rescue Errno::ENOENT
          false
        end
      end
    end
  end
end
