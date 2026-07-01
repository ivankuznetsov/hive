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

  def test_linux_default_runner_suppresses_systemctl_stdout
    with_tmp_dir do |dir|
      fake_bin = File.join(dir, "bin")
      FileUtils.mkdir_p(fake_bin)
      systemctl = File.join(fake_bin, "systemctl")
      File.write(systemctl, "#!/bin/sh\necho systemctl-noise\nexit 0\n")
      FileUtils.chmod(0755, systemctl)

      with_env("PATH" => [ fake_bin, ENV.fetch("PATH", "") ].join(File::PATH_SEPARATOR)) do
        installer = Hive::Commands::Daemon::ServiceInstaller.new(
          host_os: "linux",
          home: dir,
          binary_path: "/tmp/hive",
          systemctl_available: true
        )

        out, _err = capture_io do
          assert_equal :written, installer.install!(autostart: true).kind
        end

        assert_equal "", out
      end
    end
  end

  def test_linux_without_systemd_writes_unit_and_reports_autostart_unavailable
    with_tmp_dir do |dir|
      commands = []
      installer = Hive::Commands::Daemon::ServiceInstaller.new(
        host_os: "linux",
        home: dir,
        binary_path: "/tmp/hive",
        systemctl_available: false,
        runner: ->(argv) { commands << argv }
      )

      result = installer.install!(autostart: true)
      assert_equal :autostart_unavailable, result.kind,
                   "no systemd-user is a known-platform limitation, not a failure"
      assert File.exist?(File.join(dir, ".config/systemd/user/hive-daemon.service")),
             "unit must still be written so the operator can enable autostart later"
      assert_empty commands
      assert installer.messages.any? { |msg| msg.include?("autostart was not enabled") }
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
      assert_equal :failed, result.kind
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

  # Regression: ProgramArguments wrap the binary in a /bin/sh precheck, so the
  # `exec "$0" "$@"` marker is embedded in the -c script string. The probe must
  # return the hive binary ($0 slot), NOT the "daemon"/"web" subcommand that
  # follows it (which previously produced a permanent false "path" drift).
  def test_installed_launchd_exec_binary_returns_hive_not_subcommand
    with_tmp_dir do |dir|
      installer = Hive::Commands::Daemon::ServiceInstaller.new(
        host_os: "darwin23", home: dir, binary_path: "/opt/hive/bin/hive",
        runner: ->(_argv) { }
      )
      installer.install!(autostart: false)

      assert_equal "/opt/hive/bin/hive", installer.installed_exec_binary
    end
  end

  def test_installed_systemd_exec_binary_returns_hive_path
    with_tmp_dir do |dir|
      installer = Hive::Commands::Daemon::ServiceInstaller.new(
        host_os: "linux-gnu", home: dir, binary_path: "/usr/local/bin/hive",
        systemctl_available: true, runner: ->(_argv) { }
      )
      installer.install!(autostart: false)

      assert_equal "/usr/local/bin/hive", installer.installed_exec_binary
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
      assert_equal :failed, result.kind
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
      assert_equal :unsupported, result.kind
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
      assert_equal :drifted, result.kind
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
      assert_equal :drifted, result.kind
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

  # ── Ruby version-manager shim detection (PR #113 follow-up) ────────────
  # The gem's bin/hive uses `#!/usr/bin/env ruby`. The unit's baked
  # PATH must include the active Ruby manager's shim dir so the
  # shebang resolves to a Ruby with the gem's dependencies, not
  # system Ruby (which on a mise/rbenv/asdf workstation has none of
  # them and crashes with `cannot load such file -- thor (LoadError)`).

  # Build an installer that fakes `which("ruby")` to point at a
  # path under one of the manager directories, mimicking what the
  # operator's interactive shell would resolve.
  def installer_with_ruby_at(dir, ruby_relative)
    hive = File.join(dir, "bin", "hive")
    FileUtils.mkdir_p(File.dirname(hive))
    File.write(hive, "#!/bin/sh\n")
    FileUtils.chmod(0755, hive)
    ruby_path = File.join(dir, ruby_relative)
    FileUtils.mkdir_p(File.dirname(ruby_path))
    File.write(ruby_path, "#!/bin/sh\n")
    FileUtils.chmod(0755, ruby_path)
    installer = Hive::Commands::Daemon::ServiceInstaller.new(
      host_os: "linux", home: dir, binary_path: hive, systemctl_available: false
    )
    installer.define_singleton_method(:which) do |name|
      name == "ruby" ? ruby_path : nil
    end
    installer
  end

  def assert_unit_path_includes(dir, shim_template, msg)
    unit_body = File.read(File.join(dir, ".config/systemd/user/hive-daemon.service"))
    path_line = unit_body.lines.find { |l| l.start_with?("Environment=PATH=") }
    refute_nil path_line, "no Environment=PATH= line"
    assert_includes path_line, shim_template, msg
  end

  def test_path_includes_mise_shims_when_ruby_resolves_under_mise
    with_tmp_dir do |dir|
      installer = installer_with_ruby_at(dir, ".local/share/mise/installs/ruby/3.4.7/bin/ruby")
      installer.install!(autostart: false)
      assert_unit_path_includes(dir, "%h/.local/share/mise/shims",
        "mise-managed Ruby must inject %h/.local/share/mise/shims into PATH or the daemon's `env ruby` falls through to system Ruby which lacks gem deps")
    end
  end

  def test_path_includes_rbenv_shims_when_ruby_resolves_under_rbenv
    with_tmp_dir do |dir|
      installer = installer_with_ruby_at(dir, ".rbenv/versions/3.4.7/bin/ruby")
      installer.install!(autostart: false)
      assert_unit_path_includes(dir, "%h/.rbenv/shims",
        "rbenv-managed Ruby must inject %h/.rbenv/shims into PATH")
    end
  end

  def test_path_includes_asdf_shims_when_ruby_resolves_under_asdf
    with_tmp_dir do |dir|
      installer = installer_with_ruby_at(dir, ".asdf/installs/ruby/3.4.7/bin/ruby")
      installer.install!(autostart: false)
      assert_unit_path_includes(dir, "%h/.asdf/shims",
        "asdf-managed Ruby must inject %h/.asdf/shims into PATH")
    end
  end

  def test_path_stays_minimal_when_ruby_is_system_install
    with_tmp_dir do |dir|
      installer = installer_with_ruby_at(dir, "usr/bin/ruby")
      installer.install!(autostart: false)
      unit_body = File.read(File.join(dir, ".config/systemd/user/hive-daemon.service"))
      path_line = unit_body.lines.find { |l| l.start_with?("Environment=PATH=") }.strip
      assert_equal "Environment=PATH=%h/.local/bin:/usr/local/bin:/usr/bin:/bin", path_line,
        "system Ruby installs use the minimal PATH; no manager shim should be injected"
    end
  end

  def test_path_stays_minimal_when_ruby_not_on_path
    # The which("ruby") probe returning nil mirrors a host that
    # doesn't have ruby on PATH at install time. The installer
    # should emit the minimal PATH and let the operator deal with
    # the missing prereq via `hive doctor`.
    with_tmp_dir do |dir|
      hive = File.join(dir, "bin", "hive")
      FileUtils.mkdir_p(File.dirname(hive))
      File.write(hive, "#!/bin/sh\n")
      FileUtils.chmod(0755, hive)
      installer = Hive::Commands::Daemon::ServiceInstaller.new(
        host_os: "linux", home: dir, binary_path: hive, systemctl_available: false
      )
      installer.define_singleton_method(:which) { |_| nil }
      installer.install!(autostart: false)
      unit_body = File.read(File.join(dir, ".config/systemd/user/hive-daemon.service"))
      path_line = unit_body.lines.find { |l| l.start_with?("Environment=PATH=") }.strip
      assert_equal "Environment=PATH=%h/.local/bin:/usr/local/bin:/usr/bin:/bin", path_line
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
      assert_equal :upgraded, result.kind
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
      assert_equal :upgraded, result.kind
      assert_includes commands, %w[systemctl --user daemon-reload]
      assert_includes commands, %w[systemctl --user restart hive-daemon],
                      "force upgrade should restart the running unit so new Environment= lines take effect; enable --now would no-op an already-enabled unit"
      refute_includes commands, %w[systemctl --user enable --now hive-daemon]
      # The daemon's upgrade_restart_warning hook (moved from inline to a
      # subclass override during the ServiceInstaller::Base extraction) must
      # still surface the TimeoutStopSec block warning before the blocking
      # restart. Pins the one moved behavior the byte-identical net misses.
      assert installer.messages.any? { |msg| msg.include?("TimeoutStopSec") && msg.include?("900s") },
             "force-upgrade restart must warn about the up-to-900s block, got: #{installer.messages.inspect}"
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

  def test_envelope_platform_maps_macos_and_unsupported_hosts
    macos = Hive::Commands::Daemon::ServiceInstaller.new(host_os: "darwin23")
    unsupported = Hive::Commands::Daemon::ServiceInstaller.new(host_os: "freebsd14")

    assert_equal "macos", macos.envelope_platform
    assert_equal "unsupported", unsupported.envelope_platform
  end

  def test_macos_force_autostart_warns_when_unload_fails_then_loads
    with_tmp_dir do |dir|
      plist = File.join(dir, "Library/LaunchAgents/local.hive-daemon.plist")
      FileUtils.mkdir_p(File.dirname(plist))
      File.write(plist, "stale plist\n")
      commands = []
      installer = Hive::Commands::Daemon::ServiceInstaller.new(
        host_os: "darwin23",
        home: dir,
        binary_path: "/opt/hive/bin/hive",
        runner: ->(argv) { commands << argv; argv[1] != "unload" }
      )

      result = installer.install!(autostart: true, force: true)

      assert_equal :upgraded, result.kind
      assert_equal [ [ "launchctl", "unload", plist ], [ "launchctl", "load", plist ] ], commands
      assert result.restarted
      assert installer.messages.any? { |msg| msg.include?("launchctl unload returned non-zero") }
    end
  end

  def test_macos_brew_channel_without_stable_binary_uses_configured_binary
    with_tmp_dir do |dir|
      prefix = File.join(dir, "empty-brew")
      FileUtils.mkdir_p(File.join(prefix, "bin"))
      cellar_hive = "/opt/homebrew/Cellar/hive/0.1.0/bin/hive"
      installer = Hive::Commands::Daemon::ServiceInstaller.new(
        host_os: "darwin23",
        home: dir,
        binary_path: cellar_hive,
        runner: ->(_argv) { true }
      )
      installer.define_singleton_method(:install_channel) { "brew" }
      installer.define_singleton_method(:homebrew_prefixes) { [ prefix ] }

      installer.install!(autostart: false)

      plist = File.join(dir, "Library/LaunchAgents/local.hive-daemon.plist")
      assert_includes File.read(plist), "<string>#{cellar_hive}</string>"
    end
  end

  def test_install_channel_returns_nil_when_detection_config_fails
    original_detect = Hive::InstallChannel.method(:detect)
    Hive::InstallChannel.define_singleton_method(:detect) do
      raise Hive::ConfigError, "bad install-channel"
    end

    installer = Hive::Commands::Daemon::ServiceInstaller.new(host_os: "darwin23")
    assert_nil installer.send(:install_channel)
  ensure
    Hive::InstallChannel.define_singleton_method(:detect, original_detect) if original_detect
  end

  def test_systemctl_available_returns_false_when_systemctl_is_missing
    installer = Hive::Commands::Daemon::ServiceInstaller.new(host_os: "linux")
    installer.define_singleton_method(:system) do |_cmd, *_args, **_kwargs|
      raise Errno::ENOENT, "systemctl"
    end

    refute installer.send(:systemctl_available?)
  end

  def test_installed_systemd_exec_binary_returns_nil_on_unparseable_exec_line
    # A malformed ExecStart with an unterminated quote makes Shellwords.split
    # raise ArgumentError; the probe must degrade to nil (→ "unparseable"
    # binary_drift), never propagate the parse error out of a status probe.
    with_tmp_dir do |dir|
      unit = File.join(dir, ".config/systemd/user/hive-daemon.service")
      FileUtils.mkdir_p(File.dirname(unit))
      File.write(unit, %(ExecStart=/opt/hive 'unterminated daemon start\n))
      installer = Hive::Commands::Daemon::ServiceInstaller.new(
        host_os: "linux", home: dir, binary_path: "/tmp/hive", systemctl_available: false
      )

      assert_nil installer.installed_exec_binary,
                 "an unparseable ExecStart line must yield nil, not raise"
    end
  end

  def test_installed_launchd_exec_binary_fallback_without_sh_wrapper
    # A plist without the /bin/sh -c precheck (no "-c" element) exercises the
    # basename/trailing-segment fallback that finds the hive binary directly.
    with_tmp_dir do |dir|
      plist = File.join(dir, "Library/LaunchAgents/local.hive-daemon.plist")
      FileUtils.mkdir_p(File.dirname(plist))
      File.write(plist, <<~PLIST)
        <?xml version="1.0" encoding="UTF-8"?>
        <plist version="1.0">
        <dict>
          <key>ProgramArguments</key>
          <array>
            <string>/opt/hive/bin/hive</string>
            <string>daemon</string>
            <string>start</string>
          </array>
        </dict>
        </plist>
      PLIST
      installer = Hive::Commands::Daemon::ServiceInstaller.new(
        host_os: "darwin23", home: dir, binary_path: "/opt/hive/bin/hive", runner: ->(_argv) { }
      )

      assert_equal "/opt/hive/bin/hive", installer.installed_exec_binary,
                   "a plist without the sh wrapper must still resolve the hive binary by trailing /hive"
    end
  end

  def test_installed_launchd_exec_binary_returns_nil_on_malformed_plist_xml
    # Corrupt plist XML raises REXML::ParseException; the probe swallows it and
    # returns nil so a broken unit surfaces as "unparseable", not a backtrace.
    with_tmp_dir do |dir|
      plist = File.join(dir, "Library/LaunchAgents/local.hive-daemon.plist")
      FileUtils.mkdir_p(File.dirname(plist))
      File.write(plist, "<plist><dict><key>Program</key><string>oops</dict>")
      installer = Hive::Commands::Daemon::ServiceInstaller.new(
        host_os: "darwin23", home: dir, binary_path: "/opt/hive/bin/hive", runner: ->(_argv) { }
      )

      assert_nil installer.installed_exec_binary,
                 "malformed plist XML must degrade to nil in a status probe"
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
