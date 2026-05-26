require "cgi"
require "fileutils"
require "hive/install_channel"
require "rbconfig"
require "shellwords"

module Hive
  module Commands
    class Daemon
      class ServiceInstaller
        attr_reader :messages, :last_backup_path, :last_restart_invoked

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
          @runner = runner || ->(argv) { system(*argv, out: File::NULL) }
          @systemctl_available = systemctl_available
          @messages = []
          @last_backup_path = nil
          @last_restart_invoked = false
        end

        # `force:` overwrites an existing unit whose content differs from
        # the current template. The previous content is preserved as a
        # timestamped `<path>.bak-<timestamp>` so user hand-edits aren't
        # lost silently. On Linux with autostart, force also triggers a
        # `restart` instead of `enable --now` — restart is the only way
        # to pick up new Environment= lines from an already-running unit.
        def install!(autostart:, force: false)
          @last_backup_path = nil
          @last_restart_invoked = false
          case platform
          when :macos then install_macos!(autostart: autostart, force: force)
          when :linux then install_linux!(autostart: autostart, force: force)
          when :unsupported_host
            @messages << "daemon autostart not supported on this platform; run `hive daemon start` manually."
            :unsupported
          end
        end

        # Wire-friendly platform key for the install envelope. Mirrors
        # the schema's `platform` enum (`linux` / `macos` / `unsupported`).
        def envelope_platform
          case platform
          when :linux then "linux"
          when :macos then "macos"
          else "unsupported"
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
              # ignored. Unload first (plist may not be currently
              # loaded; that's benign), then load the refreshed file.
              # Capture the unload exit code in `messages` so the
              # operator can distinguish "plist wasn't loaded yet"
              # (benign) from "launchd refused to unload" (real
              # failure — the subsequent `load` would then silently
              # no-op against the still-loaded old plist and the
              # operator's `--force` would lie about restarting).
              unload_ok = @runner.call([ "launchctl", "unload", path ])
              unless unload_ok
                @messages << "launchctl unload returned non-zero for #{path} (benign if plist " \
                             "was not loaded; otherwise launchd refused — run `launchctl bootout " \
                             "gui/$(id -u) #{path}` to force unload, then re-run `hive daemon install --force`)"
              end
              @last_restart_invoked = true
            end
            ok = @runner.call([ "launchctl", "load", path ])
            unless ok
              @messages << "launchctl load failed for #{path}; run `launchctl load #{path}` manually"
              return :failed
            end
          end
          # Preserve the write_result distinction (:written / :upgraded /
          # :unchanged) for the operator-facing success summary in
          # `Hive::Commands::Daemon#emit_install_success_summary`. A flat
          # :ok would hide whether install actually wrote, upgraded, or
          # no-op'd.
          write_result
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
                  @last_restart_invoked = true
                  # The unit's TimeoutStopSec=900 means restart can
                  # block the caller up to ~15 minutes if children are
                  # still draining. Surface the worst case BEFORE the
                  # blocking call so operators don't Ctrl-C halfway
                  # through and leave the upgrade half-applied.
                  @messages << "restarting hive-daemon; if the running daemon is mid-tick with " \
                               "active children, this can block up to TimeoutStopSec (900s by " \
                               "default) before returning"
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
          # Preserve the write_result distinction for the operator-facing
          # success summary (see install_macos! comment).
          write_result
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
            @last_backup_path = backup_path
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

        # Per-manager root → shim dir. The keys are checked against
        # the realpath of the active `ruby` interpreter; the matching
        # value is the shim directory injected into the unit's
        # `Environment=PATH=`. All paths use `%h` so systemd expands
        # them per-user at runtime. chruby and RVM are absent because
        # they don't use a shim directory — they modify PATH per
        # shell, which the unit's static Environment= can't replicate.
        RUBY_SHIM_MANAGERS = {
          ".local/share/mise" => "%h/.local/share/mise/shims",
          ".rbenv" => "%h/.rbenv/shims",
          ".asdf" => "%h/.asdf/shims"
        }.freeze

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

        # The unit's Environment=PATH= must let `#!/usr/bin/env ruby`
        # in the gem's bin/hive wrapper resolve to a Ruby that has
        # the gem's dependencies installed. On stock Linux that's
        # /usr/bin/ruby + the system gem store, which works. On
        # workstations using mise / rbenv / asdf to manage Ruby
        # versions, the system Ruby has none of the project's gems
        # and the daemon crashes with `cannot load such file -- thor
        # (LoadError)` the first time it tries to start.
        #
        # Detect the active `ruby` interpreter's path and, if it
        # lives under a known version manager's installs directory,
        # prepend the matching shim directory to the baked PATH so
        # `env ruby` picks up the right interpreter when the daemon
        # forks. If no manager is detected, the minimal PATH
        # (sufficient for system-Ruby installs) is preserved.
        def build_path_line
          base = %w[%h/.local/bin /usr/local/bin /usr/bin /bin]
          shim = ruby_shim_dir
          base.insert(1, shim) if shim
          "Environment=PATH=#{base.join(':')}"
        end

        def ruby_shim_dir
          ruby_path = which("ruby")
          return nil unless ruby_path

          resolved = File.exist?(ruby_path) ? File.realpath(ruby_path) : ruby_path
          RUBY_SHIM_MANAGERS.each do |root_segment, shim_template|
            mgr_root = File.join(@home, root_segment)
            return shim_template if resolved.start_with?("#{mgr_root}/")
          end
          nil
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
