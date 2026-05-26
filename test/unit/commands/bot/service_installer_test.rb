require "test_helper"
require "hive/commands/bot/service_installer"

class BotServiceInstallerTest < Minitest::Test
  include HiveTestHelper

  def test_linux_writes_systemd_unit_without_start_when_autostart_false
    with_tmp_dir do |dir|
      commands = []
      hive = File.join(dir, "bin", "hive")
      FileUtils.mkdir_p(File.dirname(hive))
      File.write(hive, "#!/bin/sh\n")
      FileUtils.chmod(0755, hive)

      installer = Hive::Commands::Bot::ServiceInstaller.new(
        host_os: "linux-gnu",
        home: dir,
        binary_path: hive,
        systemctl_available: true,
        runner: ->(argv) { commands << argv }
      )

      installer.install!(autostart: false)
      unit = File.join(dir, ".config/systemd/user/hive-bot.service")
      assert File.exist?(unit)
      body = File.read(unit)
      assert_includes body, "ExecStart=#{hive} bot start --foreground"
      assert_includes body, "Environment=PATH=",
                       "minimal PATH must be rewritten so the bot's bin/hive shebang resolves a Ruby with gem deps"
      refute_includes body, "HIVE_TELEGRAM_BOT_TOKEN",
                       "the bot loads ~/.config/hive/.env itself; no inline token belongs in the unit"
      refute_includes body, "HIVE_BIN",
                       "only the daemon's status_consumer needs HIVE_BIN; the bot unit must not carry it"
      refute_includes body, "TimeoutStopSec",
                       "the bot has no in-flight child drain; no 900s stop timeout belongs here"
      assert_empty commands
    end
  end

  def test_linux_autostart_invokes_enable_when_systemd_available
    with_tmp_dir do |dir|
      commands = []
      installer = Hive::Commands::Bot::ServiceInstaller.new(
        host_os: "linux",
        home: dir,
        binary_path: "/tmp/hive",
        systemctl_available: true,
        runner: ->(argv) { commands << argv }
      )

      result = installer.install!(autostart: true)
      assert_equal :written, result
      assert_includes commands, %w[systemctl --user daemon-reload]
      assert_includes commands, %w[systemctl --user enable --now hive-bot]
    end
  end

  def test_linux_without_systemd_writes_unit_and_reports_autostart_unavailable
    with_tmp_dir do |dir|
      commands = []
      installer = Hive::Commands::Bot::ServiceInstaller.new(
        host_os: "linux",
        home: dir,
        binary_path: "/tmp/hive",
        systemctl_available: false,
        runner: ->(argv) { commands << argv }
      )

      result = installer.install!(autostart: true)
      assert_equal :autostart_unavailable, result,
                   "no systemd-user is a known-platform limitation, not a failure"
      assert File.exist?(File.join(dir, ".config/systemd/user/hive-bot.service")),
             "unit must still be written so the operator can enable autostart later"
      assert_empty commands
      assert installer.messages.any? { |msg| msg.include?("hive bot start") },
             "graceful-degradation message should tell the operator to run `hive bot start` manually"
    end
  end

  def test_linux_autostart_returns_failed_when_systemctl_enable_fails
    with_tmp_dir do |dir|
      installer = Hive::Commands::Bot::ServiceInstaller.new(
        host_os: "linux",
        home: dir,
        binary_path: "/tmp/hive",
        systemctl_available: true,
        runner: ->(_argv) { false }
      )

      result = installer.install!(autostart: true)
      assert_equal :failed, result
      assert installer.messages.any? { |msg| msg.include?("enable --now hive-bot") },
             "recovery message should name the manual `enable --now hive-bot` command, got: #{installer.messages.inspect}"
    end
  end

  def test_macos_writes_plist_and_loads_on_autostart
    with_tmp_dir do |dir|
      commands = []
      installer = Hive::Commands::Bot::ServiceInstaller.new(
        host_os: "darwin23",
        home: dir,
        binary_path: "/opt/hive/bin/hive",
        runner: ->(argv) { commands << argv }
      )

      installer.install!(autostart: true)
      plist = File.join(dir, "Library/LaunchAgents/local.hive-bot.plist")
      assert File.exist?(plist)
      body = File.read(plist)
      assert_includes body, "<string>/opt/hive/bin/hive</string>"
      assert_includes body, "<string>bot</string>"
      assert_includes body, "<string>start</string>"
      assert_includes body, "<string>--foreground</string>"
      assert_includes body, "<key>RunAtLoad</key>"
      assert_includes body, "<key>KeepAlive</key>"
      refute_includes body, "HIVE_TELEGRAM_BOT_TOKEN",
                       "the bot plist must not embed a token; the bot loads ~/.config/hive/.env itself"
      assert_equal [ [ "launchctl", "load", plist ] ], commands
    end
  end

  def test_freebsd_returns_unsupported_with_friendly_skip_message
    with_tmp_dir do |dir|
      installer = Hive::Commands::Bot::ServiceInstaller.new(
        host_os: "freebsd14",
        home: dir,
        binary_path: "/tmp/hive",
        runner: ->(_argv) { true }
      )

      result = installer.install!(autostart: true)
      assert_equal :unsupported, result
      assert installer.messages.any? { |msg| msg.include?("bot autostart not supported") && msg.include?("hive bot start") },
             "freebsd install should surface a friendly skip message, got: #{installer.messages.inspect}"
    end
  end

  def test_drifted_existing_unit_is_not_overwritten_without_force
    with_tmp_dir do |dir|
      unit = File.join(dir, ".config/systemd/user/hive-bot.service")
      FileUtils.mkdir_p(File.dirname(unit))
      File.write(unit, "custom\n")
      installer = Hive::Commands::Bot::ServiceInstaller.new(
        host_os: "linux",
        home: dir,
        binary_path: "/tmp/hive",
        systemctl_available: false
      )

      result = installer.install!(autostart: false)
      assert_equal :drifted, result
      assert_equal "custom\n", File.read(unit)
      assert installer.messages.any? { |msg| msg.include?("hive bot install --force") }
    end
  end

  def test_force_overwrites_drifted_unit_and_writes_backup
    with_tmp_dir do |dir|
      unit = File.join(dir, ".config/systemd/user/hive-bot.service")
      FileUtils.mkdir_p(File.dirname(unit))
      File.write(unit, "previous-stale-content\n")
      installer = Hive::Commands::Bot::ServiceInstaller.new(
        host_os: "linux",
        home: dir,
        binary_path: "/tmp/hive",
        systemctl_available: false
      )

      result = installer.install!(autostart: false, force: true)
      assert_equal :upgraded, result
      backups = Dir["#{unit}.bak-*"]
      assert_equal 1, backups.size,
                   "force must preserve prior content as a timestamped .bak so user hand-edits aren't silently destroyed"
      assert_equal "previous-stale-content\n", File.read(backups.first)
      assert_includes File.read(unit), "ExecStart=/tmp/hive bot start --foreground"
    end
  end

  # ── Ruby version-manager shim detection ──────────────────────────────
  # The gem's bin/hive uses `#!/usr/bin/env ruby`. The unit's baked PATH
  # must include the active Ruby manager's shim dir so the shebang
  # resolves to a Ruby with the gem's dependencies, not system Ruby.

  def installer_with_ruby_at(dir, ruby_relative)
    hive = File.join(dir, "bin", "hive")
    FileUtils.mkdir_p(File.dirname(hive))
    File.write(hive, "#!/bin/sh\n")
    FileUtils.chmod(0755, hive)
    ruby_path = File.join(dir, ruby_relative)
    FileUtils.mkdir_p(File.dirname(ruby_path))
    File.write(ruby_path, "#!/bin/sh\n")
    FileUtils.chmod(0755, ruby_path)
    installer = Hive::Commands::Bot::ServiceInstaller.new(
      host_os: "linux", home: dir, binary_path: hive, systemctl_available: false
    )
    installer.define_singleton_method(:which) do |name|
      name == "ruby" ? ruby_path : nil
    end
    installer
  end

  def test_path_includes_mise_shims_when_ruby_resolves_under_mise
    with_tmp_dir do |dir|
      installer = installer_with_ruby_at(dir, ".local/share/mise/installs/ruby/3.4.7/bin/ruby")
      installer.install!(autostart: false)
      unit_body = File.read(File.join(dir, ".config/systemd/user/hive-bot.service"))
      path_line = unit_body.lines.find { |l| l.start_with?("Environment=PATH=") }
      refute_nil path_line, "no Environment=PATH= line"
      assert_includes path_line, "%h/.local/share/mise/shims",
        "mise-managed Ruby must inject %h/.local/share/mise/shims into PATH or the bot's `env ruby` falls through to system Ruby which lacks gem deps"
    end
  end
end
