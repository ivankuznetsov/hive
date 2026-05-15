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
        cleanup_project_state(projects)
        @output.puts "hive: core uninstall cleanup complete"
        @output.puts "hive: remove the binary with your install channel (brew uninstall hive, yay -R hive-bin, or remove ~/.local/bin/hive)"
        @output.puts "hive: skills are managed by your agent marketplace; remove them with claude/codex/pi plugin commands"
        0
      end

      private

      def registered_projects
        Hive::Config.registered_projects
      rescue Hive::ConfigError
        []
      end

      def deregister_daemon
        case @host_os
        when /darwin/i
          plist = File.expand_path("~/Library/LaunchAgents/local.hive-daemon.plist")
          @runner.call([ "launchctl", "unload", plist ]) if File.exist?(plist)
          FileUtils.rm_f(plist)
        when /linux/i
          @runner.call(%w[systemctl --user disable --now hive-daemon])
          unit = File.expand_path("~/.config/systemd/user/hive-daemon.service")
          FileUtils.rm_f(unit)
          @runner.call(%w[systemctl --user daemon-reload])
        end
      end

      def remove_user_config_and_cache
        FileUtils.rm_rf(Hive::Paths.config_home)
        FileUtils.rm_rf(Hive::Paths.cache_home)
      end

      def remove_data_versions
        [ "v#{Hive::VERSION}", Hive::VERSION ].each do |version|
          FileUtils.rm_rf(File.join(Hive::Paths.data_home, version))
        end
      end

      def cleanup_project_state(projects)
        if @force_purge_state
          FileUtils.rm_rf(Hive::Paths.state_home)
          projects.each { |project| FileUtils.rm_rf(project["hive_state_path"]) }
          return
        end

        @output.puts "hive: preserving #{Hive::Paths.state_home}"
        return if @purge
        return if projects.empty?
        return unless prompt_yes?("Remove .hive-state directories from registered projects? [y/N]: ")

        projects.each { |project| FileUtils.rm_rf(project["hive_state_path"]) }
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
