require "test_helper"
require "hive/commands/daemon/service_installer"

class DaemonServiceInstallerTest < Minitest::Test
  include HiveTestHelper

  def test_linux_writes_systemd_unit_without_start_when_autostart_false
    with_tmp_dir do |dir|
      commands = []
      hive = File.join(dir, "bin", "hive")
      FileUtils.mkdir_p(File.dirname(hive))
      File.write(hive, "#!/bin/sh\n")
      FileUtils.chmod(0755, hive)

      installer = Hive::Commands::Daemon::ServiceInstaller.new(
        host_os: "linux-gnu",
        home: dir,
        binary_path: hive,
        systemctl_available: true,
        runner: ->(argv) { commands << argv }
      )

      installer.install!(autostart: false)
      unit = File.join(dir, ".config/systemd/user/hive-daemon.service")
      assert File.exist?(unit)
      assert_includes File.read(unit), "ExecStart=#{hive} daemon start"
      assert_empty commands
    end
  end

  def test_linux_autostart_invokes_enable_when_systemd_available
    with_tmp_dir do |dir|
      commands = []
      installer = Hive::Commands::Daemon::ServiceInstaller.new(
        host_os: "linux",
        home: dir,
        binary_path: "/tmp/hive",
        systemctl_available: true,
        runner: ->(argv) { commands << argv }
      )

      installer.install!(autostart: true)
      assert_includes commands, %w[systemctl --user daemon-reload]
      assert_includes commands, %w[systemctl --user enable --now hive-daemon]
    end
  end

  def test_linux_without_systemd_writes_unit_and_warns
    with_tmp_dir do |dir|
      commands = []
      installer = Hive::Commands::Daemon::ServiceInstaller.new(
        host_os: "linux",
        home: dir,
        binary_path: "/tmp/hive",
        systemctl_available: false,
        runner: ->(argv) { commands << argv }
      )

      installer.install!(autostart: true)
      assert File.exist?(File.join(dir, ".config/systemd/user/hive-daemon.service"))
      assert_empty commands
      assert installer.messages.any? { |msg| msg.include?("systemd not detected") }
    end
  end

  def test_macos_writes_plist_and_loads_on_autostart
    with_tmp_dir do |dir|
      commands = []
      installer = Hive::Commands::Daemon::ServiceInstaller.new(
        host_os: "darwin23",
        home: dir,
        binary_path: "/opt/hive/bin/hive",
        runner: ->(argv) { commands << argv }
      )

      installer.install!(autostart: true)
      plist = File.join(dir, "Library/LaunchAgents/local.hive-daemon.plist")
      assert File.exist?(plist)
      assert_includes File.read(plist), "<string>/opt/hive/bin/hive</string>"
      assert_equal [ [ "launchctl", "load", plist ] ], commands
    end
  end

  def test_drifted_existing_unit_is_not_overwritten
    with_tmp_dir do |dir|
      unit = File.join(dir, ".config/systemd/user/hive-daemon.service")
      FileUtils.mkdir_p(File.dirname(unit))
      File.write(unit, "custom\n")
      installer = Hive::Commands::Daemon::ServiceInstaller.new(
        host_os: "linux",
        home: dir,
        binary_path: "/tmp/hive",
        systemctl_available: false
      )

      installer.install!(autostart: false)
      assert_equal "custom\n", File.read(unit)
      assert installer.messages.any? { |msg| msg.include?("leaving user-customized") }
    end
  end
end
