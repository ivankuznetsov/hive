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
      rendered = File.read(unit)
      assert_includes rendered, "ExecStart=#{hive} web"
      assert_includes rendered, "Environment=HIVE_BIN=#{hive}"
      assert_includes rendered, "StartLimitBurst=3"
      assert_includes rendered, "StartLimitIntervalSec=300"
      %w[
        HIVE_WEB_APP_DIR HIVE_WEB_ORIGIN HIVE_WEB_STORAGE_DIR HIVE_WEB_LOCAL_LOOPBACK
        HIVE_WEB_DIFF_TIMEOUT_SEC HIVE_WEB_CLONE_TIMEOUT_SEC
      ].each { |name| assert_includes rendered, "Environment=#{name}=" }
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
      rendered = File.read(plist)
      assert_includes rendered, "<string>/opt/hive/bin/hive</string>"
      assert_includes rendered, '<string>[ -x "$0" ] || exit 0; exec "$0" "$@"</string>'
      assert_match(/<key>SuccessfulExit<\/key>\s*<false\/>/, rendered)
      %w[
        HIVE_WEB_APP_DIR HIVE_WEB_ORIGIN HIVE_WEB_STORAGE_DIR HIVE_WEB_LOCAL_LOOPBACK
        HIVE_WEB_DIFF_TIMEOUT_SEC HIVE_WEB_CLONE_TIMEOUT_SEC
      ].each { |name| assert_includes rendered, "<key>#{name}</key>" }
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

  def test_restart_on_linux_reloads_systemd_then_restarts_service
    commands = []
    installer = Hive::Commands::Web::ServiceInstaller.new(
      host_os: "linux",
      runner: ->(argv) { commands << argv; true }
    )

    assert installer.restart!
    assert_equal [
      %w[systemctl --user daemon-reload],
      %w[systemctl --user restart hive-web]
    ], commands
    assert_equal [ "restarted running web service to load the refreshed application bundle" ], installer.messages
  end

  def test_restart_on_macos_unloads_then_loads_plist
    commands = []
    installer = Hive::Commands::Web::ServiceInstaller.new(
      host_os: "darwin23",
      home: "/h",
      runner: ->(argv) { commands << argv; true }
    )

    assert installer.restart!
    assert_equal [
      [ "launchctl", "unload", "/h/Library/LaunchAgents/local.hive-web.plist" ],
      [ "launchctl", "load", "/h/Library/LaunchAgents/local.hive-web.plist" ]
    ], commands
    assert_equal [ "restarted running web service to load the refreshed application bundle" ], installer.messages
  end

  def test_restart_on_unsupported_platform_raises_without_running_command
    commands = []
    installer = Hive::Commands::Web::ServiceInstaller.new(
      host_os: "freebsd14",
      runner: ->(argv) { commands << argv; true }
    )

    error = assert_raises(Hive::Error) { installer.restart! }

    assert_equal "hive web: could not restart managed web service", error.message
    assert_empty commands
    assert_empty installer.messages
  end

  def test_restart_on_linux_raises_when_systemctl_restart_fails
    commands = []
    installer = Hive::Commands::Web::ServiceInstaller.new(
      host_os: "linux",
      runner: lambda do |argv|
        commands << argv
        argv != %w[systemctl --user restart hive-web]
      end
    )

    error = assert_raises(Hive::Error) { installer.restart! }

    assert_equal "hive web: could not restart managed web service", error.message
    assert_equal [
      %w[systemctl --user daemon-reload],
      %w[systemctl --user restart hive-web]
    ], commands
    assert_empty installer.messages
  end

  def test_restart_on_macos_raises_when_launchctl_load_fails
    commands = []
    installer = Hive::Commands::Web::ServiceInstaller.new(
      host_os: "darwin23",
      home: "/h",
      runner: lambda do |argv|
        commands << argv
        argv[1] != "load"
      end
    )

    error = assert_raises(Hive::Error) { installer.restart! }

    assert_equal "hive web: could not restart managed web service", error.message
    assert_equal [
      [ "launchctl", "unload", "/h/Library/LaunchAgents/local.hive-web.plist" ],
      [ "launchctl", "load", "/h/Library/LaunchAgents/local.hive-web.plist" ]
    ], commands
    assert_empty installer.messages
  end
end
