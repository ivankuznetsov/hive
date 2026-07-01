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
        systemctl_available: true, runner: ->(_argv) { }
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

  # The service-identity hooks the base class reads when rendering units and
  # composing messages. Pinning their exact strings keeps the web unit's
  # filename/label/noun stable (a rename here silently repoints the plist
  # Label and systemd unit name).
  def test_service_identity_strings
    installer = Hive::Commands::Web::ServiceInstaller.new(host_os: "linux")

    assert_equal "hive-web", installer.service_name
    assert_equal "web", installer.cli_label
    assert_equal "web service", installer.send(:service_noun)
    assert_equal "web unit", installer.send(:unit_noun)
    assert_equal "local.hive-web", installer.launchd_label
  end

  def test_target_path_maps_per_platform
    linux = Hive::Commands::Web::ServiceInstaller.new(host_os: "linux", home: "/h")
    macos = Hive::Commands::Web::ServiceInstaller.new(host_os: "darwin23", home: "/h")

    assert_equal "/h/.config/systemd/user/hive-web.service", linux.target_path
    assert_equal "/h/Library/LaunchAgents/local.hive-web.plist", macos.target_path
  end

  def test_target_path_nil_on_unsupported_platform
    # Same contract as the daemon/bot installers: no service manager, no unit
    # path. install! reports :unsupported and service_state guards nil, so an
    # unsupported host degrades to "not installed" instead of raising.
    installer = Hive::Commands::Web::ServiceInstaller.new(host_os: "freebsd14", home: "/h")

    assert_nil installer.target_path
    state = installer.service_state
    assert_equal "unsupported", state["platform"]
    assert_equal false, state["service_installed"]
  end
end
