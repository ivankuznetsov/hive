require "test_helper"
require "hive/commands/babysit/service_installer"

class BabysitServiceInstallerTest < Minitest::Test
  include HiveTestHelper

  def test_linux_unit_runs_foreground_and_drains_before_killing_children
    with_tmp_dir do |dir|
      commands = []
      installer = Hive::Commands::Babysit::ServiceInstaller.new(
        host_os: "linux-gnu",
        home: dir,
        binary_path: "/tmp/hive",
        systemctl_available: true,
        runner: ->(argv) { commands << argv; true }
      )

      outcome = installer.install!(autostart: true)
      unit_path = File.join(dir, ".config/systemd/user/hive-babysitter.service")
      unit = File.read(unit_path)

      assert_equal :written, outcome.kind
      assert_includes unit, "ExecStart=/tmp/hive babysit start"
      refute_includes unit, "--detach"
      assert_includes unit, "KillMode=mixed"
      assert_includes unit, "TimeoutStopSec=610"
      assert_includes commands, %w[systemctl --user daemon-reload]
      assert_includes commands, %w[systemctl --user enable --now hive-babysitter]
    end
  end

  def test_macos_plist_uses_foreground_start_and_failure_only_restart
    with_tmp_dir do |dir|
      commands = []
      installer = Hive::Commands::Babysit::ServiceInstaller.new(
        host_os: "darwin23",
        home: dir,
        binary_path: "/opt/hive/bin/hive",
        runner: ->(argv) { commands << argv; true }
      )

      installer.install!(autostart: true)
      plist = File.join(dir, "Library/LaunchAgents/local.hive-babysitter.plist")
      body = File.read(plist)

      assert_includes body, "<string>/opt/hive/bin/hive</string>"
      assert_match(%r{<string>babysit</string>\s*<string>start</string>}m, body)
      refute_includes body, "<string>--detach</string>"
      assert_match(
        %r{<key>KeepAlive</key>\s*<dict>\s*<key>SuccessfulExit</key>\s*<false/>\s*</dict>}m,
        body
      )
      assert_includes body, '[ -x "$0" ] || exit 0; exec "$0" "$@"'
      assert_equal [ [ "launchctl", "load", plist ] ], commands
    end
  end

  def test_force_upgrade_preserves_the_previous_unit
    with_tmp_dir do |dir|
      unit_path = File.join(dir, ".config/systemd/user/hive-babysitter.service")
      FileUtils.mkdir_p(File.dirname(unit_path))
      File.write(unit_path, "operator-owned\n")
      installer = Hive::Commands::Babysit::ServiceInstaller.new(
        host_os: "linux",
        home: dir,
        binary_path: "/tmp/hive",
        systemctl_available: false
      )

      drift = installer.install!(autostart: false)
      assert_equal :drifted, drift.kind
      assert_equal "operator-owned\n", File.read(unit_path)

      upgraded = installer.install!(autostart: false, force: true)
      assert_equal :upgraded, upgraded.kind
      backups = Dir["#{unit_path}.bak-*"]
      assert_equal 1, backups.size
      assert_equal "operator-owned\n", File.read(backups.first)
    end
  end

  def test_service_persists_only_custom_hive_state_roots
    with_tmp_dir do |dir|
      hive_home = File.join(dir, "custom hive")
      installer = Hive::Commands::Babysit::ServiceInstaller.new(
        host_os: "linux-gnu",
        home: dir,
        binary_path: "/tmp/hive",
        environment: {
          "HIVE_HOME" => hive_home,
          "XDG_STATE_HOME" => File.join(dir, "state"),
          "ANTHROPIC_API_KEY" => "must-not-enter-service"
        },
        systemctl_available: false
      )

      installer.install!(autostart: false)
      unit = File.read(
        File.join(dir, ".config/systemd/user/hive-babysitter.service")
      )

      assert_includes unit,
                      "Environment=HIVE_HOME=#{Shellwords.escape(hive_home)}"
      assert_includes unit, "Environment=XDG_STATE_HOME=#{File.join(dir, 'state')}"
      refute_includes unit, "ANTHROPIC_API_KEY"
      refute_includes unit, "must-not-enter-service"
    end
  end

  def test_force_upgrade_warns_before_a_potentially_long_restart
    with_tmp_dir do |dir|
      unit_path = File.join(dir, ".config/systemd/user/hive-babysitter.service")
      FileUtils.mkdir_p(File.dirname(unit_path))
      File.write(unit_path, "old unit\n")
      installer = Hive::Commands::Babysit::ServiceInstaller.new(
        host_os: "linux",
        home: dir,
        binary_path: "/tmp/hive",
        systemctl_available: true,
        runner: ->(_argv) { true }
      )

      installer.install!(autostart: true, force: true)

      assert installer.messages.any? { |message| message.include?("TimeoutStopSec (610s)") }
    end
  end
end
