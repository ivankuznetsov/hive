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
      assert installer.messages.any? { |msg| msg.include?("enable systemd in WSL") }
    end
  end

  def test_linux_autostart_returns_failed_when_systemctl_enable_fails
    with_tmp_dir do |dir|
      installer = Hive::Commands::Daemon::ServiceInstaller.new(
        host_os: "linux",
        home: dir,
        binary_path: "/tmp/hive",
        systemctl_available: true,
        runner: ->(_argv) { false }
      )

      result = installer.install!(autostart: true)
      assert_equal :failed, result
      assert installer.messages.any? { |msg| msg.include?("systemctl --user enable failed") }
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

  def test_macos_autostart_returns_failed_when_launchctl_load_fails
    with_tmp_dir do |dir|
      installer = Hive::Commands::Daemon::ServiceInstaller.new(
        host_os: "darwin23",
        home: dir,
        binary_path: "/opt/hive/bin/hive",
        runner: ->(_argv) { false }
      )

      result = installer.install!(autostart: true)
      assert_equal :failed, result
      assert installer.messages.any? { |msg| msg.include?("launchctl load failed") }
    end
  end

  def test_macos_brew_channel_uses_stable_homebrew_symlink
    with_xdg_home do |dir|
      old_prefix = ENV["HOMEBREW_PREFIX"]
      begin
        prefix = File.join(dir, "brew")
        hive = File.join(prefix, "bin", "hive")
        FileUtils.mkdir_p(File.dirname(hive))
        File.write(hive, "#!/bin/sh\n")
        FileUtils.chmod(0755, hive)
        FileUtils.mkdir_p(Hive::Paths.data_home)
        File.write(File.join(Hive::Paths.data_home, "install-channel"), "brew\n")
        ENV["HOMEBREW_PREFIX"] = prefix
        installer = Hive::Commands::Daemon::ServiceInstaller.new(
          host_os: "darwin23",
          home: dir,
          binary_path: "/opt/homebrew/Cellar/hive/0.1.0/bin/hive",
          runner: ->(_argv) { true }
        )

        installer.install!(autostart: false)
        plist = File.join(dir, "Library/LaunchAgents/local.hive-daemon.plist")
        assert_includes File.read(plist), "<string>#{hive}</string>"
      ensure
        old_prefix.nil? ? ENV.delete("HOMEBREW_PREFIX") : ENV["HOMEBREW_PREFIX"] = old_prefix
      end
    end
  end

  def test_freebsd_returns_unsupported_with_friendly_skip_message
    # Tier-3 hosts (BSD, etc.) must skip cleanly with a "run `hive
    # daemon start` manually" hint rather than crash or silently no-op.
    with_tmp_dir do |dir|
      installer = Hive::Commands::Daemon::ServiceInstaller.new(
        host_os: "freebsd14",
        home: dir,
        binary_path: "/tmp/hive",
        runner: ->(_argv) { true }
      )

      result = installer.install!(autostart: true)
      assert_equal :unsupported, result
      assert installer.messages.any? { |msg| msg.include?("daemon autostart not supported") },
             "freebsd install should surface a friendly skip message, got: #{installer.messages.inspect}"
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

      result = installer.install!(autostart: false)
      assert_equal :drifted, result
      assert_equal "custom\n", File.read(unit)
      assert installer.messages.any? { |msg| msg.include?("leaving user-customized") }
    end
  end

  def test_drifted_existing_unit_skips_autostart
    with_tmp_dir do |dir|
      unit = File.join(dir, ".config/systemd/user/hive-daemon.service")
      FileUtils.mkdir_p(File.dirname(unit))
      File.write(unit, "custom\n")
      commands = []
      installer = Hive::Commands::Daemon::ServiceInstaller.new(
        host_os: "linux",
        home: dir,
        binary_path: "/tmp/hive",
        systemctl_available: true,
        runner: ->(argv) { commands << argv; true }
      )

      result = installer.install!(autostart: true)
      assert_equal :drifted, result
      assert_empty commands
      assert installer.messages.any? { |msg| msg.include?("hive daemon install --force") },
             "drift message should point users at the --force upgrade flow, got: #{installer.messages.inspect}"
    end
  end

  def test_linux_writes_hive_bin_environment_line
    with_tmp_dir do |dir|
      hive = File.join(dir, "bin", "hive")
      FileUtils.mkdir_p(File.dirname(hive))
      File.write(hive, "#!/bin/sh\n")
      FileUtils.chmod(0755, hive)

      installer = Hive::Commands::Daemon::ServiceInstaller.new(
        host_os: "linux-gnu",
        home: dir,
        binary_path: hive,
        systemctl_available: true,
        runner: ->(_argv) { true }
      )
      installer.install!(autostart: false)

      unit_body = File.read(File.join(dir, ".config/systemd/user/hive-daemon.service"))
      assert_includes unit_body, "Environment=HIVE_BIN=#{hive}",
                      "HIVE_BIN env line must point at the resolved binary so the daemon can find `hive` when systemd-user PATH excludes ~/.local/bin"
      assert_includes unit_body, "Environment=PATH=",
                      "minimal PATH must be set so the daemon's incidental shell-outs (git, etc.) keep working"
      assert_includes unit_body, "ExecStart=#{hive} daemon start"
    end
  end

  def test_linux_hive_bin_matches_exec_start_for_realpath_binary
    with_tmp_dir do |dir|
      real_hive = File.join(dir, "bin", "hive")
      FileUtils.mkdir_p(File.dirname(real_hive))
      File.write(real_hive, "#!/bin/sh\n")
      FileUtils.chmod(0755, real_hive)
      symlink = File.join(dir, "bin", "hive-symlink")
      File.symlink(real_hive, symlink)

      installer = Hive::Commands::Daemon::ServiceInstaller.new(
        host_os: "linux",
        home: dir,
        binary_path: symlink,
        systemctl_available: false
      )
      installer.install!(autostart: false)

      unit_body = File.read(File.join(dir, ".config/systemd/user/hive-daemon.service"))
      exec_line = unit_body.lines.find { |l| l.start_with?("ExecStart=") }
      env_line = unit_body.lines.find { |l| l.start_with?("Environment=HIVE_BIN=") }
      assert exec_line && env_line
      exec_path = exec_line.sub("ExecStart=", "").split(" daemon start").first
      env_path = env_line.sub("Environment=HIVE_BIN=", "").strip
      assert_equal exec_path, env_path,
                   "ExecStart and Environment=HIVE_BIN must reference the same absolute binary"
    end
  end

  def test_force_overwrites_drifted_unit_and_writes_backup
    with_tmp_dir do |dir|
      unit = File.join(dir, ".config/systemd/user/hive-daemon.service")
      FileUtils.mkdir_p(File.dirname(unit))
      File.write(unit, "previous-stale-content\n")
      commands = []
      installer = Hive::Commands::Daemon::ServiceInstaller.new(
        host_os: "linux",
        home: dir,
        binary_path: "/tmp/hive",
        systemctl_available: true,
        runner: ->(argv) { commands << argv; true }
      )

      result = installer.install!(autostart: false, force: true)
      assert_equal :upgraded, result
      backups = Dir["#{unit}.bak-*"]
      assert_equal 1, backups.size,
                   "force must preserve prior content as a timestamped .bak so user hand-edits aren't silently destroyed and a second --force doesn't clobber the original backup"
      assert_equal "previous-stale-content\n", File.read(backups.first)
      refute_equal "previous-stale-content\n", File.read(unit)
      assert_includes File.read(unit), "ExecStart=/tmp/hive daemon start"
      assert installer.messages.any? { |msg| msg.include?("upgraded existing unit") }
    end
  end

  def test_force_rotates_backups_so_repeated_upgrades_do_not_lose_original
    with_tmp_dir do |dir|
      unit = File.join(dir, ".config/systemd/user/hive-daemon.service")
      FileUtils.mkdir_p(File.dirname(unit))
      File.write(unit, "user-hand-edited\n")
      installer = Hive::Commands::Daemon::ServiceInstaller.new(
        host_os: "linux", home: dir, binary_path: "/tmp/hive-a",
        systemctl_available: false
      )
      installer.install!(autostart: false, force: true)
      # Tiny sleep so the timestamp suffix differs.
      sleep 1.1
      installer2 = Hive::Commands::Daemon::ServiceInstaller.new(
        host_os: "linux", home: dir, binary_path: "/tmp/hive-b",
        systemctl_available: false
      )
      installer2.install!(autostart: false, force: true)

      backups = Dir["#{unit}.bak-*"].sort
      assert_equal 2, backups.size, "second force must not clobber the first backup"
      assert_equal "user-hand-edited\n", File.read(backups.first),
                   "first backup must preserve the original user hand-edits"
    end
  end

  def test_force_with_autostart_restarts_running_unit
    with_tmp_dir do |dir|
      unit = File.join(dir, ".config/systemd/user/hive-daemon.service")
      FileUtils.mkdir_p(File.dirname(unit))
      File.write(unit, "stale\n")
      commands = []
      installer = Hive::Commands::Daemon::ServiceInstaller.new(
        host_os: "linux",
        home: dir,
        binary_path: "/tmp/hive",
        systemctl_available: true,
        runner: ->(argv) { commands << argv; true }
      )

      result = installer.install!(autostart: true, force: true)
      assert_equal :upgraded, result
      assert_includes commands, %w[systemctl --user daemon-reload]
      assert_includes commands, %w[systemctl --user restart hive-daemon],
                      "force upgrade should restart the running unit so new Environment= lines take effect; enable --now would no-op an already-enabled unit"
      refute_includes commands, %w[systemctl --user enable --now hive-daemon]
    end
  end

  def test_force_on_matching_template_is_unchanged
    with_tmp_dir do |dir|
      installer = Hive::Commands::Daemon::ServiceInstaller.new(
        host_os: "linux",
        home: dir,
        binary_path: "/tmp/hive",
        systemctl_available: false
      )
      installer.install!(autostart: false)
      # Second install with same args + force: file matches, no backup written
      installer2 = Hive::Commands::Daemon::ServiceInstaller.new(
        host_os: "linux",
        home: dir,
        binary_path: "/tmp/hive",
        systemctl_available: false
      )
      installer2.install!(autostart: false, force: true)

      unit = File.join(dir, ".config/systemd/user/hive-daemon.service")
      assert_empty Dir["#{unit}.bak-*"],
                   "force should not write a .bak when the existing unit already matches"
    end
  end

  def test_missing_binary_fallback_warns_loudly
    with_tmp_dir do |dir|
      old_path = ENV["PATH"]
      begin
        ENV["PATH"] = ""
        installer = Hive::Commands::Daemon::ServiceInstaller.new(
          host_os: "linux",
          home: dir,
          systemctl_available: false
        )

        installer.install!(autostart: false)
        assert installer.messages.any? { |msg| msg.include?("hive binary not found on PATH") }
      ensure
        old_path.nil? ? ENV.delete("PATH") : ENV["PATH"] = old_path
      end
    end
  end
end
