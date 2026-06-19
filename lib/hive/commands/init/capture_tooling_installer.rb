require "open3"
require "rbconfig"
require "shellwords"

require "hive/install_channel"
require "hive/visual_artifacts_readiness"

module Hive
  module Commands
    class Init
      class CaptureToolingInstaller
        PackageManager = Struct.new(:name, :executable, :needs_sudo, :argv_prefix, keyword_init: true)

        PACKAGE_NAMES = Hive::VisualArtifactsReadiness::CAPTURE_TOOLS.to_h { |name| [ name, name ] }.freeze

        def initialize(path_env: ENV["PATH"], probe: nil)
          @path_env = path_env
          @probe = probe || method(:which)
        end

        def package_manager
          @package_manager ||= detect_package_manager
        end

        def command_for(missing:)
          packages = packages_for(missing)
          return "" if packages.empty?

          Shellwords.join(command_argv(package_manager || fallback_package_manager, packages, command_display: true))
        end

        def install!(missing:, runner: method(:system_runner))
          packages = packages_for(missing)
          return :installed if packages.empty?

          manager = package_manager
          return :unsupported unless manager

          status = runner.call(command_argv(manager, packages, command_display: false))
          status_success?(status) ? :installed : :failed
        rescue StandardError
          :failed
        end

        private

        def detect_package_manager
          return pm(:pacman, "pacman", true, %w[-S --needed --noconfirm]) if executable?("pacman")

          brew = brew_executable
          return pm(:brew, brew, false, [ "install" ]) if brew

          apt = executable?("apt-get") ? "apt-get" : executable?("apt")
          return pm(:apt, apt, true, %w[install -y]) if apt

          return pm(:dnf, "dnf", true, %w[install -y]) if executable?("dnf")
          return pm(:zypper, "zypper", true, %w[install -y]) if executable?("zypper")

          nil
        end

        def pm(name, executable, needs_sudo, argv_prefix)
          PackageManager.new(name: name, executable: executable, needs_sudo: needs_sudo, argv_prefix: argv_prefix)
        end

        def fallback_package_manager
          if RbConfig::CONFIG["host_os"] =~ /darwin/i
            pm(:brew, "brew", false, [ "install" ])
          else
            pm(:apt, "apt-get", true, %w[install -y])
          end
        end

        def command_argv(manager, packages, command_display:)
          argv = [ manager.executable, *manager.argv_prefix, *packages ]
          return argv unless manager.needs_sudo

          if command_display || executable?("sudo")
            [ "sudo", *argv ]
          else
            argv
          end
        end

        def packages_for(missing)
          Array(missing).map(&:to_s).filter_map { |name| PACKAGE_NAMES[name] }
        end

        def executable?(name)
          @probe.call(name)
        end

        def brew_executable
          executable?("brew") || homebrew_prefix_brew
        end

        def homebrew_prefix_brew
          Hive::InstallChannel.homebrew_marker_paths.each do |marker_path|
            prefix = marker_path.delete_suffix("/share/hive/install-channel")
            brew = File.join(prefix, "bin", "brew")
            return brew if File.executable?(brew)
          end
          nil
        end

        def which(name)
          @path_env.to_s.split(File::PATH_SEPARATOR).each do |dir|
            path = File.join(dir, name)
            return name if File.file?(path) && File.executable?(path)
          end
          nil
        end

        def status_success?(status)
          return status.success? if status.respond_to?(:success?)

          status == true
        end

        def system_runner(argv)
          system(*argv)
        rescue SystemCallError
          false
        end
      end
    end
  end
end
