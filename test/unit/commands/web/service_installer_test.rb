require "test_helper"
require "hive/commands/web/service_installer"

class WebServiceInstallerTest < Minitest::Test
  include HiveTestHelper

  def test_linux_writes_systemd_unit_with_web_exec
    with_tmp_dir do |dir|
      hive = File.join(dir, "bin", "hive")
      FileUtils.mkdir_p(File.dirname(hive))
      File.write(hive, "#!/bin/sh\n")
      FileUtils.chmod(0o755, hive)

      installer = Hive::Commands::Web::ServiceInstaller.new(
        host_os: "linux-gnu", home: dir, binary_path: hive,
        systemctl_available: true, runner: ->(_argv) {}
      )

      installer.install!(autostart: false)
      unit = File.join(dir, ".config/systemd/user/hive-web.service")
      assert File.exist?(unit)
      assert_includes File.read(unit), "ExecStart=#{hive} web"
      assert_includes File.read(unit), "Environment=HIVE_BIN=#{hive}"
    end
  end

  def test_macos_writes_plist_with_resolved_binary
    with_tmp_dir do |dir|
      commands = []
      installer = Hive::Commands::Web::ServiceInstaller.new(
        host_os: "darwin23", home: dir, binary_path: "/opt/hive/bin/hive",
        runner: ->(argv) { commands << argv }
      )

      installer.install!(autostart: true)
      plist = File.join(dir, "Library/LaunchAgents/local.hive-web.plist")
      assert File.exist?(plist)
      assert_includes File.read(plist), "<string>/opt/hive/bin/hive</string>"
      assert_equal [ [ "launchctl", "load", plist ] ], commands
    end
  end
end
