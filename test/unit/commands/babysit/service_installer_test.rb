require "test_helper"
require "hive/commands/babysit/service_installer"
require "hive/commands/daemon/service_installer"
require "hive/commands/bot/service_installer"
require "hive/commands/web/service_installer"

class BabysitServiceInstallerTest < Minitest::Test
  include HiveTestHelper

  # Execute version-only fake CLIs with only the environment rendered for the
  # service: an interactive-shell probe would miss this regression.
  def test_service_environment_can_run_managed_agents_without_managed_ruby
    with_tmp_dir do |dir|
      agent_bin = File.join(dir, "tools with spaces % and &", "bin")
      node_bin = File.join(dir, "node", "bin")
      FileUtils.mkdir_p([ agent_bin, node_bin ])
      File.write(File.join(agent_bin, "codex"), "#!/usr/bin/env node\n")
      File.write(File.join(node_bin, "node"), "#!/bin/sh\nprintf 'codex-cli 1.0.0\\n'\n")
      FileUtils.chmod(0755, [ File.join(agent_bin, "codex"), File.join(node_bin, "node") ])
      installers = [ Hive::Commands::Babysit::ServiceInstaller, Hive::Commands::Daemon::ServiceInstaller,
                     Hive::Commands::Bot::ServiceInstaller, Hive::Commands::Web::ServiceInstaller ]
      installers.product(%w[linux darwin]).each do |installer_class, platform|
        installer = installer_class.new(
          host_os: platform, home: dir, binary_path: "/usr/bin/hive",
          environment: { "PATH" => "#{agent_bin}:#{node_bin}:/usr/bin:/bin" },
          systemctl_available: false, launchctl_available: false
        )
        installer.define_singleton_method(:ruby_shim_dir) { nil }
        installer.install!(autostart: false)
        environment = rendered_environment(installer, platform, dir)
        profile = AgentCliRuntime::Profiles.fetch(:codex)
        assert_equal "1.0.0", profile.check_version!(env: environment)
        assert_includes environment.fetch("PATH"), agent_bin
        assert_includes environment.fetch("PATH"), node_bin
      end
    end
  end

  def test_service_environment_preserves_explicit_agent_override_without_credentials
    with_tmp_dir do |dir|
      FileUtils.mkdir_p(File.join(dir, "custom tools"))
      executable = File.join(dir, "custom tools", 'codex %n "quoted"')
      File.write(executable, "#!/bin/sh\nprintf 'codex-cli 1.0.0\\n'\n")
      FileUtils.chmod(0755, executable)
      installers = [ Hive::Commands::Babysit::ServiceInstaller, Hive::Commands::Daemon::ServiceInstaller,
                     Hive::Commands::Bot::ServiceInstaller, Hive::Commands::Web::ServiceInstaller ]
      installers.product(%w[linux darwin]).each do |installer_class, platform|
        installer = installer_class.new(
          host_os: platform, home: dir, binary_path: "/usr/bin/hive",
          environment: { "PATH" => "/usr/bin:/bin", "HIVE_CODEX_BIN" => executable,
                         "OPENAI_API_KEY" => "must-not-be-persisted" },
          systemctl_available: false, launchctl_available: false
        )
        installer.install!(autostart: false)
        environment = rendered_environment(installer, platform, dir)
        assert_equal executable, environment.fetch("HIVE_CODEX_BIN")
        assert_equal "1.0.0", AgentCliRuntime::Profiles.fetch(:codex).check_version!(env: environment)
        refute_includes File.read(installer.target_path), "must-not-be-persisted"
      end
    end
  end

  def rendered_environment(installer, platform, home)
    body = File.read(installer.target_path)
    if platform == "linux"
      body.lines.grep(/^Environment=/).to_h do |line|
        assignment = Shellwords.split(line.delete_prefix("Environment=")).fetch(0)
        key, value = assignment.split("=", 2)
        [ key, value.gsub("%%", "\0").gsub("%h", home).gsub("\0", "%") ]
      end
    else
      require "rexml/document"
      doc = REXML::Document.new(body)
      dict = REXML::XPath.first(doc, "//key[.='EnvironmentVariables']/following-sibling::dict[1]")
      dict.elements.to_a.each_slice(2).to_h { |key, value| [ key.text, value.text ] }
    end
  end

  def test_labels_the_managed_unit_for_operator_messages
    installer = Hive::Commands::Babysit::ServiceInstaller.new(host_os: "linux")

    assert_equal "babysitter unit", installer.send(:unit_noun)
  end

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
      assert_includes unit, "ExecStart=/tmp/hive babysit start --context local"
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
      assert_equal [ [ "launchctl", "load", plist ] ],
                   commands.select { |argv| %w[load unload].include?(argv[1]) }
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
