require "cgi"
require "fileutils"
require "hive/install_channel"
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

        # `force:` overwrites an existing unit whose content differs from
        # the current template. The previous content is preserved as
        # `<path>.bak` so a user's hand-edits aren't lost silently. On
        # Linux with autostart, force also triggers a `restart` instead
        # of `enable --now` — restart is the only way to pick up new
        # Environment= lines from an already-running unit.
        def install!(autostart:, force: false)
          case platform
          when :macos then install_macos!(autostart: autostart, force: force)
          when :linux then install_linux!(autostart: autostart, force: force)
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

        def install_macos!(autostart:, force:)
          path = target_path
          write_result = write_if_safe(path, render_launchd, force: force)
          return :drifted if write_result == :drifted

          if autostart
            if write_result == :upgraded
              # launchd does not pick up a rewritten plist while the
              # service is loaded; new EnvironmentVariables would be
              # ignored. Unload first (best-effort: plist may not be
              # currently loaded), then load the refreshed file.
              @runner.call([ "launchctl", "unload", path ])
            end
            ok = @runner.call([ "launchctl", "load", path ])
            unless ok
              @messages << "launchctl load failed for #{path}; run `launchctl load #{path}` manually"
              return :failed
            end
          end
          write_result == :upgraded ? :upgraded : :ok
        end

        def install_linux!(autostart:, force:)
          path = target_path
          write_result = write_if_safe(path, render_systemd, force: force)
          return :drifted if write_result == :drifted

          if autostart
            if systemctl_available?
              ok_reload = @runner.call(%w[systemctl --user daemon-reload])
              # Force-upgrade restarts the running unit so new
              # Environment= lines take effect. `:written` and
              # `:unchanged` use `enable --now` which is idempotent on
              # an already-enabled-and-running unit and restores retry-
              # after-failed-enable semantics when the file already
              # matches the template.
              start_argv =
                if write_result == :upgraded
                  %w[systemctl --user restart hive-daemon]
                else
                  %w[systemctl --user enable --now hive-daemon]
                end
              ok_start = @runner.call(start_argv)
              unless ok_reload && ok_start
                @messages << "systemctl --user enable failed; run `systemctl --user enable --now hive-daemon` manually"
                return :failed
              end
            else
              @messages << "systemd not detected; enable systemd in WSL or run `hive daemon start` manually."
            end
          end
          write_result == :upgraded ? :upgraded : :ok
        end

        def write_if_safe(path, content, force: false)
          if File.exist?(path)
            existing = File.read(path)
            return :unchanged if existing == content

            unless force
              @messages << "daemon service already exists at #{path}; leaving user-customized file untouched. Re-run with `hive daemon install --force` to overwrite (the previous file will be backed up to #{path}.bak-<timestamp>)."
              return :drifted
            end

            backup_path = "#{path}.bak-#{Time.now.utc.strftime('%Y%m%dT%H%M%SZ')}"
            atomic_write(backup_path, existing)
            atomic_write(path, content)
            @messages << "upgraded existing unit at #{path}; previous content backed up to #{backup_path}"
            return :upgraded
          end

          FileUtils.mkdir_p(File.dirname(path))
          atomic_write(path, content)
          :written
        end

        # Tempfile + rename in the same directory. Either the target has
        # the old content or the new content; no torn-write window can
        # leave it truncated or partially written. Mirrors the pattern
        # `Hive::Markers#write_atomic` uses for state files.
        def atomic_write(path, content)
          FileUtils.mkdir_p(File.dirname(path))
          tmp = "#{path}.tmp.#{Process.pid}.#{rand(1_000_000)}"
          begin
            File.write(tmp, content)
            File.rename(tmp, path)
          ensure
            File.unlink(tmp) if File.exist?(tmp)
          end
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
          if (brew_binary = homebrew_stable_binary)
            return File.expand_path(brew_binary)
          end

          path = @binary_path || which("hive")
          if path
            return File.expand_path(path) if @binary_path && path == @binary_path

            return File.exist?(path) ? File.realpath(path) : path
          end

          fallback = File.expand_path("../../../../bin/hive", __dir__)
          @messages << "hive binary not found on PATH; falling back to #{fallback}. Re-run `hive init` from the installed hive binary if this is not intended."
          File.exist?(fallback) ? File.realpath(fallback) : fallback
        end

        def homebrew_stable_binary
          return nil unless platform == :macos
          return nil unless install_channel == "brew"

          homebrew_prefixes.each do |prefix|
            path = File.join(prefix, "bin", "hive")
            return path if File.file?(path) && File.executable?(path)
          end
          nil
        end

        def homebrew_prefixes
          [ ENV["HOMEBREW_PREFIX"], "/opt/homebrew", "/usr/local" ].compact.uniq
        end

        def install_channel
          Hive::InstallChannel.detect
        rescue Hive::ConfigError
          nil
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
