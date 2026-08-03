require "fileutils"
require "rbconfig"
require "securerandom"
require "yaml"
require "hive/config"
require "hive/paths"

module Hive
  module Commands
    class Uninstall
      def initialize(purge: false, force_purge_state: false, input: $stdin, output: $stdout, runner: nil,
                     host_os: RbConfig::CONFIG["host_os"])
        @purge = purge
        @force_purge_state = force_purge_state
        @input = input
        @output = output
        @runner = runner || ->(argv) { system(*argv) }
        @host_os = host_os
      end

      def call
        projects = registered_projects
        deregister_daemon
        deregister_bot
        deregister_web
        remove_user_config_and_cache
        remove_data_versions
        remove_user_symlinks
        cleanup_project_state(projects)
        @output.puts "hive: core uninstall cleanup complete"
        @output.puts "hive: remove the binary with your install channel (brew uninstall hive, yay -R hive-bin, or remove the gem payload at ~/.local/share/hive/gems/ and ~/.local/bin/hive)"
        @output.puts "hive: skills are managed by your agent marketplace; remove them with your agent CLI's plugin commands"
        0
      end

      private

      def registered_projects
        Hive::Config.registered_projects
      rescue Hive::ConfigError => e
        @output.puts "hive: warning: could not read registered projects (#{e.message}); skipping per-project cleanup"
        []
      end

      def deregister_daemon
        stop_foreground_daemon
        require "hive/commands/daemon/service_installer"
        deregister_unit(Hive::Commands::Daemon::ServiceInstaller.new(**service_installer_options))
      end

      # Mirror of deregister_daemon for the opt-in bot autostart service
      # (installed by `hive bot install`).
      def deregister_bot
        stop_foreground_bot
        require "hive/commands/bot/service_installer"
        deregister_unit(Hive::Commands::Bot::ServiceInstaller.new(**service_installer_options))
      end

      def deregister_web
        require "hive/commands/web/service_installer"
        # Uninstall only needs the installer's platform-derived identity.
        # Supplying an inert config keeps malformed global web settings from
        # aborting teardown before the unit can be deregistered and the later
        # config/cache/data cleanup can run.
        deregister_unit(
          Hive::Commands::Web::ServiceInstaller.new(config: {}, **service_installer_options)
        )
      end

      # Keep command ordering and presentation here while delegating the
      # platform-neutral disable/remove/reload transaction to UserService.
      def deregister_unit(installer)
        path = installer.target_path
        return unless path

        result = installer.remove!
        if result.diagnostics.include?(:unsafe_unit_path)
          @output.puts "hive: refusing to follow symlink at #{path}; remove it manually"
        elsif result.diagnostics.include?(:manager_disable_failed)
          if installer.envelope_platform == "macos"
            @output.puts "hive: warning: launchctl unload failed for #{path}; leaving it in place. Fix launchd state and re-run `hive uninstall`."
          else
            service = installer.service_name
            @output.puts "hive: warning: systemctl --user disable failed for #{service}; leaving #{path} in place. Fix systemd state and re-run `hive uninstall`."
          end
        elsif result.diagnostics.include?(:stale_after_manager_change)
          @output.puts "hive: warning: #{path} changed while its service was being disabled; leaving it in place. Re-run `hive uninstall`."
        elsif result.diagnostics.include?(:daemon_reload_failed)
          @output.puts "hive: warning: systemctl --user daemon-reload failed after removing #{path}; run it manually"
        elsif result.failed?
          @output.puts "hive: warning: could not remove #{path}; leaving it in place and continuing"
        end
      end

      def service_installer_options
        {
          host_os: @host_os,
          runner: @runner,
          systemctl_available: @host_os.match?(/linux/i),
          launchctl_available: @host_os.match?(/darwin/i)
        }
      end

      def stop_foreground_bot
        pid_file = File.join(Hive::Paths.state_home, ".bot.pid")
        return unless File.exist?(pid_file)

        # The bot's pid file is a YAML Hash payload ({pid:, started_at:}),
        # unlike the daemon's bare-integer .daemon.pid. Guard is_a?(Hash)
        # before indexing: a corrupt/legacy bare scalar is still valid YAML
        # (e.g. "12345" parses to an Integer), and Integer#[] would raise an
        # unrescued TypeError that aborts the entire uninstall after only the
        # daemon was deregistered. Mirror Bot#pid_file_payload's guard, and
        # rescue Psych::Exception (covers SyntaxError AND DisallowedClass for
        # a stray Date/Symbol scalar) so a malformed file degrades to a no-op.
        payload = YAML.safe_load(File.read(pid_file))
        return unless payload.is_a?(Hash)

        pid = payload["pid"].to_i
        return if pid.zero?

        Process.kill("TERM", pid)
      rescue Errno::EPERM
        # The process is alive but owned by another uid, so we can't TERM
        # it. Don't abort the destructive uninstall, but the operator's bot
        # may keep running against state we're about to delete — so unlike
        # the corrupt-pid / dead-pid cases this gets an explicit warning
        # rather than a silent no-op.
        @output.puts "hive: warning: bot pid #{pid} is alive but could not be signalled (EPERM); it may still be running after uninstall"
      rescue Errno::ESRCH, Errno::ENOENT, Psych::Exception
        nil
      end

      def remove_user_config_and_cache
        if Hive::Paths.hive_home_collapsed?
          # HIVE_HOME collapses config/data/state/cache onto a single
          # directory. `rm_rf(config_home)` here would also wipe
          # state_home and erase work — refuse and tell the user.
          @output.puts "hive: HIVE_HOME collapses config/data/state into one directory; skipping config/cache wipe to preserve state"
          return
        end

        FileUtils.rm_rf(Hive::Paths.config_home)
        FileUtils.rm_rf(Hive::Paths.cache_home)
      end

      def remove_data_versions
        return if Hive::Paths.hive_home_collapsed?

        data_home = Hive::Paths.data_home
        return unless File.directory?(data_home)

        Dir.children(data_home).each do |entry|
          next unless entry.start_with?("v") || entry =~ /\A\d+\.\d+\.\d+/

          FileUtils.rm_rf(File.join(data_home, entry))
        end
      end

      def remove_user_symlinks
        bin_home = Hive::Paths.bin_home
        %w[hive hv].each do |name|
          link = File.join(bin_home, name)
          next unless managed_bash_launcher_link?(link, name)

          quarantine = File.join(
            bin_home,
            ".hive-uninstall-#{name}-#{Process.pid}-#{SecureRandom.hex(6)}"
          )
          File.rename(link, quarantine)
          if managed_bash_launcher_link?(quarantine, name)
            File.unlink(quarantine)
          else
            restore_replaced_launcher(quarantine, link)
          end
        rescue Errno::ENOENT
          next
        end
      end

      def restore_replaced_launcher(quarantine, link)
        if !File.exist?(link) && !File.symlink?(link)
          File.rename(quarantine, link)
          @output.puts "hive: warning: launcher changed during uninstall; restored #{link}"
        else
          @output.puts "hive: warning: launcher changed during uninstall; preserved it at #{quarantine}"
        end
      rescue SystemCallError => e
        @output.puts "hive: warning: could not restore changed launcher #{link}: #{e.message}; preserved it at #{quarantine}"
      end

      # `install.sh` publishes absolute user-bin symlinks to wrappers under an
      # authenticated bash-channel data home. Basename alone is not ownership:
      # an operator may already have an unrelated `hive` or `hv` symlink.
      # Require the exact managed layout, current-UID regular wrapper, and a
      # stable current-UID bash marker before removing the launcher.
      def managed_bash_launcher_link?(link, name)
        return false unless File.symlink?(link)

        target = File.expand_path(File.readlink(link), File.dirname(link))
        bin_dir = File.dirname(target)
        gems_dir = File.dirname(bin_dir)
        data_home = File.dirname(gems_dir)
        return false unless File.basename(target) == name
        return false unless File.basename(bin_dir) == "bin"
        return false unless File.basename(gems_dir) == "gems"
        return false unless File.basename(data_home) == "hive"
        return false unless managed_bash_data_home?(data_home)

        target_stat = File.lstat(target)
        return false unless target_stat.file? && target_stat.uid == Process.uid

        marker = File.join(data_home, "install-channel")
        stable_owned_file_content(marker, max_bytes: 16)&.strip == "bash"
      rescue SystemCallError
        false
      end

      def managed_bash_data_home?(candidate)
        expanded_candidate = File.expand_path(candidate)
        return true if expanded_candidate == File.expand_path(Hive::Paths.data_home)

        prefix = stable_owned_file_content(
          File.join(Hive::Paths.data_home, "install-prefix"),
          max_bytes: 4_096
        )&.strip
        return false if prefix.to_s.empty?

        expanded_candidate == File.join(File.expand_path(prefix), "hive")
      rescue ArgumentError
        false
      end

      def stable_owned_file_content(path, max_bytes:)
        before = File.lstat(path)
        return nil unless before.file? &&
                          before.uid == Process.uid &&
                          before.nlink == 1 &&
                          before.size <= max_bytes

        flags = File::RDONLY | File::NONBLOCK
        flags |= File::NOFOLLOW if defined?(File::NOFOLLOW)
        File.open(path, flags) do |file|
          opened = file.stat
          return nil unless opened.dev == before.dev &&
                            opened.ino == before.ino &&
                            opened.size == before.size

          file.read(max_bytes)
        end
      rescue SystemCallError
        nil
      end

      def cleanup_project_state(projects)
        if @force_purge_state
          unless Hive::Paths.hive_home_collapsed?
            FileUtils.rm_rf(Hive::Paths.state_home)
          end
          projects.each { |project| FileUtils.rm_rf(project["hive_state_path"]) }
          return
        end

        @output.puts "hive: preserving #{Hive::Paths.state_home}"
        return if @purge
        return if projects.empty?

        @output.puts "hive: registered projects:"
        projects.each do |project|
          @output.puts "  - #{project['name']} → #{project['hive_state_path']}"
        end
        return unless prompt_yes?("Remove .hive-state directories from the projects listed above? [y/N]: ")

        projects.each { |project| FileUtils.rm_rf(project["hive_state_path"]) }
      end

      # Best-effort: find a running foreground daemon writing under
      # state_home and TERM it before purge would yank the floor.
      # No-ops if the daemon isn't running.
      def stop_foreground_daemon
        pid_file = File.join(Hive::Paths.state_home, ".daemon.pid")
        return unless File.exist?(pid_file)

        pid = File.read(pid_file).strip.to_i
        return if pid.zero?

        Process.kill("TERM", pid)
      rescue Errno::ESRCH, Errno::EPERM, Errno::ENOENT
        nil
      end

      def prompt_yes?(message)
        @output.print message
        @output.flush
        answer = @input.gets.to_s.strip.downcase
        answer == "y" || answer == "yes"
      end
    end
  end
end
