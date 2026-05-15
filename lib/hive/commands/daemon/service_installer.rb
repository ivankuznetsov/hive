require "cgi"
require "fileutils"
require "rbconfig"

module Hive
  module Commands
    class Daemon
      class ServiceInstaller
        attr_reader :messages

        def initialize(host_os: RbConfig::CONFIG["host_os"], home: nil, binary_path: nil, runner: nil,
                       systemctl_available: nil)
          @host_os = host_os
          @home = File.expand_path(home || ENV["HIVE_HOME"] || Dir.home)
          @binary_path = binary_path
          @runner = runner || ->(argv) { system(*argv) }
          @systemctl_available = systemctl_available
          @messages = []
        end

        def install!(autostart:)
          case platform
          when :macos then install_macos!(autostart: autostart)
          when :linux then install_linux!(autostart: autostart)
          else
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
          @runner.call([ "launchctl", "load", path ]) if autostart
          :ok
        end

        def install_linux!(autostart:)
          path = target_path
          write_if_safe(path, render_systemd)
          if autostart
            if systemctl_available?
              @runner.call(%w[systemctl --user daemon-reload])
              @runner.call(%w[systemctl --user enable --now hive-daemon])
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
          template.sub(/^ExecStart=.*$/, "ExecStart=#{resolved_binary} daemon start")
        end

        def render_launchd
          template = File.read(File.expand_path("../../../../examples/launchd/hive-daemon.plist", __dir__))
          escaped_binary = CGI.escapeHTML(resolved_binary)
          escaped_home = CGI.escapeHTML(@home)
          template
            .gsub(%r{<string>/Users/YOU/\.local/bin/hive</string>}, "<string>#{escaped_binary}</string>")
            .gsub("/Users/YOU/Library/Logs", "#{escaped_home}/Library/Logs")
            .gsub("/Users/YOU/.local/bin", File.dirname(escaped_binary))
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
          else :unsupported
          end
        end

        def systemctl_available?
          return @systemctl_available unless @systemctl_available.nil?

          system("systemctl", "--user", "--version", out: File::NULL, err: File::NULL)
        end
      end
    end
  end
end
