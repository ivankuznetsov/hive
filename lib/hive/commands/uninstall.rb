require "fileutils"
require "rbconfig"
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
        remove_user_config_and_cache
        remove_data_versions
        remove_user_symlinks
        cleanup_project_state(projects)
        @output.puts "hive: core uninstall cleanup complete"
        @output.puts "hive: remove the binary with your install channel (brew uninstall hive, yay -R hive-bin, or remove the versioned payload at ~/.local/share/hive/<version>/ and ~/.local/bin/hive)"
        @output.puts "hive: skills are managed by your agent marketplace; remove them with claude/codex/pi plugin commands"
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
        case @host_os
        when /darwin/i
          plist = File.expand_path("~/Library/LaunchAgents/local.hive-daemon.plist")
          if File.exist?(plist)
            ok = @runner.call([ "launchctl", "unload", plist ])
            @output.puts "hive: warning: launchctl unload failed for #{plist}" unless ok
            safe_unlink(plist)
          end
        when /linux/i
          unit = File.expand_path("~/.config/systemd/user/hive-daemon.service")
          if File.exist?(unit)
            ok = @runner.call(%w[systemctl --user disable --now hive-daemon])
            @output.puts "hive: warning: systemctl --user disable failed for hive-daemon" unless ok
            safe_unlink(unit)
            @runner.call(%w[systemctl --user daemon-reload])
          end
        end
      end

      # Refuse to delete via a symlink: an attacker who pre-plants
      # `~/Library/LaunchAgents/local.hive-daemon.plist -> /etc/passwd`
      # would otherwise get an arbitrary user-writable file unlinked.
      def safe_unlink(path)
        stat = File.lstat(path)
        if stat.symlink?
          @output.puts "hive: refusing to follow symlink at #{path}; remove it manually"
          return
        end
        FileUtils.rm_f(path)
      rescue Errno::ENOENT
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
          next unless File.symlink?(link)

          File.unlink(link)
        rescue Errno::ENOENT
          next
        end
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
