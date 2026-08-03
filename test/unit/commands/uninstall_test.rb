require "test_helper"
require "hive/commands/uninstall"
require "hive/user_service"

class UninstallCommandTest < Minitest::Test
  include HiveTestHelper

  def setup_install_tree(project)
    FileUtils.mkdir_p(Hive::Paths.config_home)
    FileUtils.mkdir_p(Hive::Paths.cache_home)
    FileUtils.mkdir_p(File.join(Hive::Paths.data_home, "v#{Hive::VERSION}", "bin"))
    FileUtils.mkdir_p(File.join(Hive::Paths.state_home, "projects", "work"))
    FileUtils.mkdir_p(File.join(project, ".hive-state", "stages"))
    File.write(
      Hive::Config.global_config_path,
      {
        "registered_projects" => [
          { "name" => "proj", "path" => project, "hive_state_path" => File.join(project, ".hive-state") }
        ]
      }.to_yaml
    )
  end

  def test_registered_project_read_failure_warns_and_skips_project_cleanup
    with_xdg_home do
      out = StringIO.new

      with_replaced_singleton_method(Hive::Config, :registered_projects, lambda {
        raise Hive::ConfigError, "broken registry"
      }) do
        Hive::Commands::Uninstall.new(
          purge: true,
          output: out,
          runner: ->(_argv) { true },
          host_os: "freebsd"
        ).call
      end

      assert_match(/could not read registered projects \(broken registry\)/, out.string)
    end
  end

  def test_macos_launch_agent_unload_success_removes_plist
    with_xdg_home do
      plist = File.expand_path("~/Library/LaunchAgents/local.hive-daemon.plist")
      FileUtils.mkdir_p(File.dirname(plist))
      File.write(plist, "plist\n")
      calls = []

      Hive::Commands::Uninstall.new(
        purge: true,
        output: StringIO.new,
        runner: ->(argv) { calls << argv; true },
        host_os: "darwin"
      ).call

      mutations = calls.reject { |argv| argv == %w[launchctl list local.hive-daemon] }
      assert_equal [ [ "launchctl", "unload", plist ] ], mutations
      assert calls.any? { |argv| argv == %w[launchctl list local.hive-daemon] },
             "removal should observe launchd before mutating it"
      refute File.exist?(plist)
    end
  end

  def test_macos_launch_agent_unload_failure_leaves_plist_in_place
    with_xdg_home do
      plist = File.expand_path("~/Library/LaunchAgents/local.hive-daemon.plist")
      FileUtils.mkdir_p(File.dirname(plist))
      File.write(plist, "plist\n")
      out = StringIO.new

      Hive::Commands::Uninstall.new(
        purge: true,
        output: out,
        runner: ->(_argv) { false },
        host_os: "darwin"
      ).call

      assert File.exist?(plist)
      assert_match(/launchctl unload failed/, out.string)
      assert_match(/leaving it in place/, out.string)
    end
  end

  def test_remove_data_versions_preserves_non_version_entries
    with_xdg_home do
      versioned = File.join(Hive::Paths.data_home, "1.2.3")
      named = File.join(Hive::Paths.data_home, "vnext")
      kept = File.join(Hive::Paths.data_home, "notes")
      [ versioned, named, kept ].each { |path| FileUtils.mkdir_p(path) }

      Hive::Commands::Uninstall.new(output: StringIO.new).send(:remove_data_versions)

      refute File.exist?(versioned)
      refute File.exist?(named)
      assert File.exist?(kept)
    end
  end

  def test_remove_user_symlinks_removes_hive_and_hv_links
    with_xdg_home do
      bin = Hive::Paths.bin_home
      FileUtils.mkdir_p(bin)
      managed_bin = File.join(Hive::Paths.data_home, "gems", "bin")
      FileUtils.mkdir_p(managed_bin)
      File.write(File.join(Hive::Paths.data_home, "install-channel"), "bash\n")
      %w[hive hv].each do |name|
        target = File.join(managed_bin, name)
        File.write(target, "bin\n")
        File.symlink(target, File.join(bin, name))
      end

      Hive::Commands::Uninstall.new(output: StringIO.new).send(:remove_user_symlinks)

      refute File.exist?(File.join(bin, "hive"))
      refute File.exist?(File.join(bin, "hv"))
    end
  end

  def test_remove_user_symlinks_tolerates_disappearing_link
    with_xdg_home do
      bin = Hive::Paths.bin_home
      FileUtils.mkdir_p(bin)
      managed_bin = File.join(Hive::Paths.data_home, "gems", "bin")
      FileUtils.mkdir_p(managed_bin)
      File.write(File.join(Hive::Paths.data_home, "install-channel"), "bash\n")
      target = File.join(managed_bin, "hive")
      link = File.join(bin, "hive")
      File.write(target, "bin\n")
      File.symlink(target, link)

      with_replaced_singleton_method(File, :rename, ->(*_paths) { raise Errno::ENOENT }) do
        Hive::Commands::Uninstall.new(output: StringIO.new).send(:remove_user_symlinks)
      end

      assert File.symlink?(link)
    end
  end

  def test_remove_user_symlinks_restores_a_concurrent_replacement
    with_xdg_home do
      bin = Hive::Paths.bin_home
      FileUtils.mkdir_p(bin)
      managed_bin = File.join(Hive::Paths.data_home, "gems", "bin")
      FileUtils.mkdir_p(managed_bin)
      File.write(File.join(Hive::Paths.data_home, "install-channel"), "bash\n")
      managed = File.join(managed_bin, "hive")
      operator = File.join(bin, "operator-hive")
      link = File.join(bin, "hive")
      File.write(managed, "managed\n")
      File.write(operator, "operator\n")
      File.symlink(managed, link)
      original_rename = File.method(:rename)
      calls = 0
      replacement_race = lambda do |source, destination|
        calls += 1
        if calls == 1
          File.unlink(source)
          File.symlink(operator, source)
        end
        original_rename.call(source, destination)
      end
      output = StringIO.new

      with_replaced_singleton_method(File, :rename, replacement_race) do
        Hive::Commands::Uninstall.new(output: output).send(:remove_user_symlinks)
      end

      assert File.symlink?(link)
      assert_equal operator, File.readlink(link)
      assert_match(/changed during uninstall; restored/, output.string)
      assert_empty Dir.glob(File.join(bin, ".hive-uninstall-*"))
    end
  end

  def test_remove_user_symlinks_preserves_a_replacement_that_arrives_after_quarantine
    with_xdg_home do
      bin = Hive::Paths.bin_home
      FileUtils.mkdir_p(bin)
      managed_bin = File.join(Hive::Paths.data_home, "gems", "bin")
      FileUtils.mkdir_p(managed_bin)
      File.write(File.join(Hive::Paths.data_home, "install-channel"), "bash\n")
      managed = File.join(managed_bin, "hive")
      operator = File.join(bin, "operator-hive")
      link = File.join(bin, "hive")
      File.write(managed, "managed\n")
      File.write(operator, "operator\n")
      File.symlink(managed, link)
      original_rename = File.method(:rename)
      original_readlink = File.method(:readlink)
      moved = false
      output = StringIO.new

      replacement_race = lambda do |source, destination|
        original_rename.call(source, destination)
        unless moved
          moved = true
          File.symlink(operator, source)
        end
      end
      swapped_quarantine = lambda do |path|
        if moved && File.basename(path).start_with?(".hive-uninstall-hive-")
          File.unlink(path)
          File.symlink(operator, path)
        end
        original_readlink.call(path)
      end

      with_replaced_singleton_method(File, :rename, replacement_race) do
        with_replaced_singleton_method(File, :readlink, swapped_quarantine) do
          Hive::Commands::Uninstall.new(output: output).send(:remove_user_symlinks)
        end
      end

      assert_equal operator, File.readlink(link)
      assert_match(/changed during uninstall; preserved it at/, output.string)
      assert_equal 1, Dir.glob(File.join(bin, ".hive-uninstall-*")).length
    end
  end

  def test_managed_launcher_check_fails_closed_when_link_disappears_during_inspection
    with_xdg_home do
      bin = Hive::Paths.bin_home
      managed_bin = File.join(Hive::Paths.data_home, "gems", "bin")
      FileUtils.mkdir_p([ bin, managed_bin ])
      File.write(File.join(Hive::Paths.data_home, "install-channel"), "bash\n")
      target = File.join(managed_bin, "hive")
      link = File.join(bin, "hive")
      File.write(target, "managed\n")
      File.symlink(target, link)

      with_replaced_singleton_method(File, :readlink, ->(_path) { raise Errno::ENOENT }) do
        refute Hive::Commands::Uninstall.new(output: StringIO.new).send(:managed_bash_launcher_link?, link, "hive")
      end
    end
  end

  def test_restore_replaced_launcher_keeps_quarantine_when_restore_fails
    with_xdg_home do
      bin = Hive::Paths.bin_home
      FileUtils.mkdir_p(bin)
      quarantine = File.join(bin, ".hive-uninstall-hive-test")
      link = File.join(bin, "hive")
      File.write(quarantine, "operator\n")
      output = StringIO.new

      with_replaced_singleton_method(File, :rename, ->(*_paths) { raise Errno::EPERM, "operation not permitted" }) do
        Hive::Commands::Uninstall.new(output: output).send(:restore_replaced_launcher, quarantine, link)
      end

      assert File.exist?(quarantine)
      assert_match(/could not restore changed launcher/, output.string)
    end
  end

  def test_remove_user_symlinks_preserves_unowned_links
    with_xdg_home do
      bin = Hive::Paths.bin_home
      FileUtils.mkdir_p(bin)
      target = File.join(bin, "operator-hive")
      File.write(target, "operator\n")
      %w[hive hv].each { |name| File.symlink(target, File.join(bin, name)) }

      Hive::Commands::Uninstall.new(output: StringIO.new).send(:remove_user_symlinks)

      assert File.symlink?(File.join(bin, "hive"))
      assert File.symlink?(File.join(bin, "hv"))
      assert_equal "operator\n", File.read(target)
    end
  end

  def test_remove_user_symlinks_preserves_a_same_shape_lookalike_install
    with_xdg_home do |dir|
      bin = Hive::Paths.bin_home
      FileUtils.mkdir_p(bin)
      lookalike_home = File.join(dir, "operator", "hive")
      target = File.join(lookalike_home, "gems", "bin", "hive")
      FileUtils.mkdir_p(File.dirname(target))
      File.write(target, "operator\n")
      File.write(File.join(lookalike_home, "install-channel"), "bash\n")
      link = File.join(bin, "hive")
      File.symlink(target, link)

      Hive::Commands::Uninstall.new(output: StringIO.new).send(:remove_user_symlinks)

      assert File.symlink?(link)
      assert_equal "operator\n", File.read(target)
    end
  end

  def test_remove_user_symlinks_removes_a_recorded_prefix_install
    with_xdg_home do |dir|
      bin = Hive::Paths.bin_home
      FileUtils.mkdir_p(bin)
      prefix = File.join(dir, "prefix")
      prefixed_data_home = File.join(prefix, "hive")
      target = File.join(prefixed_data_home, "gems", "bin", "hive")
      FileUtils.mkdir_p(File.dirname(target))
      FileUtils.mkdir_p(Hive::Paths.data_home)
      File.write(target, "managed\n")
      File.write(File.join(prefixed_data_home, "install-channel"), "bash\n")
      File.write(File.join(Hive::Paths.data_home, "install-prefix"), "#{prefix}\n")
      link = File.join(bin, "hive")
      File.symlink(target, link)

      Hive::Commands::Uninstall.new(output: StringIO.new).send(:remove_user_symlinks)

      refute File.symlink?(link)
    end
  end

  def test_remove_user_symlinks_treats_a_malformed_prefix_as_unowned
    with_xdg_home do |dir|
      bin = Hive::Paths.bin_home
      FileUtils.mkdir_p(bin)
      FileUtils.mkdir_p(Hive::Paths.data_home)
      File.write(File.join(Hive::Paths.data_home, "install-prefix"), "/tmp/bad\0prefix\n")
      lookalike_home = File.join(dir, "operator", "hive")
      target = File.join(lookalike_home, "gems", "bin", "hive")
      FileUtils.mkdir_p(File.dirname(target))
      File.write(target, "operator\n")
      File.write(File.join(lookalike_home, "install-channel"), "bash\n")
      link = File.join(bin, "hive")
      File.symlink(target, link)

      Hive::Commands::Uninstall.new(output: StringIO.new).send(:remove_user_symlinks)

      assert File.symlink?(link)
      assert_equal "operator\n", File.read(target)
    end
  end

  def test_remove_user_symlinks_rejects_a_symlinked_channel_marker
    with_xdg_home do |dir|
      bin = Hive::Paths.bin_home
      managed_bin = File.join(Hive::Paths.data_home, "gems", "bin")
      FileUtils.mkdir_p(bin)
      FileUtils.mkdir_p(managed_bin)
      target = File.join(managed_bin, "hive")
      File.write(target, "bin\n")
      File.symlink(target, File.join(bin, "hive"))
      external_marker = File.join(dir, "operator-marker")
      File.write(external_marker, "bash\n")
      File.symlink(external_marker, File.join(Hive::Paths.data_home, "install-channel"))

      Hive::Commands::Uninstall.new(output: StringIO.new).send(:remove_user_symlinks)

      assert File.symlink?(File.join(bin, "hive"))
      assert_equal "bash\n", File.read(external_marker)
    end
  end

  def test_stop_foreground_daemon_terms_nonzero_pid
    with_xdg_home do
      FileUtils.mkdir_p(Hive::Paths.state_home)
      File.write(File.join(Hive::Paths.state_home, ".daemon.pid"), "123\n")
      signals = []

      with_replaced_singleton_method(Process, :kill, ->(signal, pid) { signals << [ signal, pid ] }) do
        Hive::Commands::Uninstall.new(output: StringIO.new).send(:stop_foreground_daemon)
      end

      assert_equal [ [ "TERM", 123 ] ], signals
    end
  end

  def test_stop_foreground_daemon_ignores_zero_pid
    with_xdg_home do
      FileUtils.mkdir_p(Hive::Paths.state_home)
      File.write(File.join(Hive::Paths.state_home, ".daemon.pid"), "0\n")

      with_replaced_singleton_method(Process, :kill, ->(_signal, _pid) { raise "should not kill zero pid" }) do
        Hive::Commands::Uninstall.new(output: StringIO.new).send(:stop_foreground_daemon)
      end
    end
  end

  def test_stop_foreground_daemon_ignores_stale_pid
    with_xdg_home do
      FileUtils.mkdir_p(Hive::Paths.state_home)
      File.write(File.join(Hive::Paths.state_home, ".daemon.pid"), "123\n")

      with_replaced_singleton_method(Process, :kill, ->(_signal, _pid) { raise Errno::ESRCH }) do
        Hive::Commands::Uninstall.new(output: StringIO.new).send(:stop_foreground_daemon)
      end
    end
  end

  def test_linux_bot_unit_disable_removes_unit
    with_xdg_home do
      unit = File.expand_path("~/.config/systemd/user/hive-bot.service")
      FileUtils.mkdir_p(File.dirname(unit))
      File.write(unit, "unit\n")
      calls = []

      Hive::Commands::Uninstall.new(
        purge: true, output: StringIO.new,
        runner: ->(argv) { calls << argv; true }, host_os: "linux"
      ).call

      assert_includes calls, %w[systemctl --user disable --now hive-bot]
      refute File.exist?(unit), "bot unit must be removed after a successful disable"
    end
  end

  def test_linux_web_unit_disable_removes_unit
    with_xdg_home do
      unit = File.expand_path("~/.config/systemd/user/hive-web.service")
      FileUtils.mkdir_p(File.dirname(unit))
      File.write(unit, "unit\n")
      calls = []

      Hive::Commands::Uninstall.new(
        purge: true, output: StringIO.new,
        runner: ->(argv) { calls << argv; true }, host_os: "linux"
      ).call

      assert_includes calls, %w[systemctl --user disable --now hive-web]
      refute File.exist?(unit), "web unit must be removed after a successful disable"
    end
  end

  def test_linux_web_deregistration_ignores_malformed_web_config_and_failure_does_not_abort_cleanup
    with_xdg_home do
      unit = File.expand_path("~/.config/systemd/user/hive-web.service")
      FileUtils.mkdir_p(File.dirname(unit))
      File.write(unit, "unit\n")
      FileUtils.mkdir_p(Hive::Paths.cache_home)
      File.write(File.join(Hive::Paths.cache_home, "remove-me"), "cached\n")
      out = StringIO.new

      with_replaced_singleton_method(Hive::Config, :load_global_web, lambda {
        raise Hive::ConfigError, "malformed web config"
      }) do
        status = Hive::Commands::Uninstall.new(
          purge: true, output: out,
          runner: ->(_argv) { false }, host_os: "linux"
        ).call

        assert_equal 0, status
      end

      assert File.exist?(unit), "a failed systemd deregistration must preserve the web unit"
      refute File.exist?(Hive::Paths.cache_home), "later uninstall cleanup must still run"
      assert_match(/systemctl --user disable failed for hive-web/, out.string)
      assert_match(/core uninstall cleanup complete/, out.string)
    end
  end

  def test_macos_web_deregistration_ignores_malformed_web_config_and_failure_does_not_abort_cleanup
    with_xdg_home do
      plist = File.expand_path("~/Library/LaunchAgents/local.hive-web.plist")
      FileUtils.mkdir_p(File.dirname(plist))
      File.write(plist, "plist\n")
      FileUtils.mkdir_p(Hive::Paths.cache_home)
      File.write(File.join(Hive::Paths.cache_home, "remove-me"), "cached\n")
      out = StringIO.new

      with_replaced_singleton_method(Hive::Config, :load_global_web, lambda {
        raise Hive::ConfigError, "malformed web config"
      }) do
        status = Hive::Commands::Uninstall.new(
          purge: true, output: out,
          runner: ->(_argv) { false }, host_os: "darwin"
        ).call

        assert_equal 0, status
      end

      assert File.exist?(plist), "a failed launchd deregistration must preserve the web plist"
      refute File.exist?(Hive::Paths.cache_home), "later uninstall cleanup must still run"
      assert_match(/launchctl unload failed for #{Regexp.escape(plist)}/, out.string)
      assert_match(/core uninstall cleanup complete/, out.string)
    end
  end

  def test_linux_bot_disable_failure_leaves_unit_in_place
    with_xdg_home do
      unit = File.expand_path("~/.config/systemd/user/hive-bot.service")
      FileUtils.mkdir_p(File.dirname(unit))
      File.write(unit, "unit\n")
      out = StringIO.new

      Hive::Commands::Uninstall.new(
        purge: true, output: out,
        runner: ->(argv) { argv.include?("hive-bot") ? false : true }, host_os: "linux"
      ).call

      assert File.exist?(unit)
      assert_match(/systemctl --user disable failed for hive-bot/, out.string)
    end
  end

  def test_macos_bot_plist_unload_removes_plist
    with_xdg_home do
      plist = File.expand_path("~/Library/LaunchAgents/local.hive-bot.plist")
      FileUtils.mkdir_p(File.dirname(plist))
      File.write(plist, "plist\n")
      calls = []

      Hive::Commands::Uninstall.new(
        purge: true, output: StringIO.new,
        runner: ->(argv) { calls << argv; true }, host_os: "darwin"
      ).call

      assert_includes calls, [ "launchctl", "unload", plist ]
      refute File.exist?(plist)
    end
  end

  def test_macos_bot_plist_unload_failure_leaves_plist_in_place
    with_xdg_home do
      plist = File.expand_path("~/Library/LaunchAgents/local.hive-bot.plist")
      FileUtils.mkdir_p(File.dirname(plist))
      File.write(plist, "plist\n")
      out = StringIO.new

      Hive::Commands::Uninstall.new(
        purge: true, output: out,
        runner: ->(_argv) { false }, host_os: "darwin"
      ).call

      assert File.exist?(plist), "a failed launchctl unload must leave the bot plist in place"
      assert_match(/launchctl unload failed for #{Regexp.escape(plist)}/, out.string)
    end
  end

  def test_bot_teardown_noops_when_unit_absent
    with_xdg_home do
      calls = []

      Hive::Commands::Uninstall.new(
        purge: true, output: StringIO.new,
        runner: ->(argv) { calls << argv; true }, host_os: "linux"
      ).call

      refute(calls.any? { |argv| argv.include?("hive-bot") },
             "no bot unit present → no bot service-manager calls")
    end
  end

  def test_stop_foreground_bot_terms_pid_from_yaml_payload
    with_xdg_home do
      FileUtils.mkdir_p(Hive::Paths.state_home)
      # The bot pid file is YAML, not a bare integer.
      File.write(File.join(Hive::Paths.state_home, ".bot.pid"),
                 { "pid" => 456, "started_at" => "2026-05-27T00:00:00Z" }.to_yaml)
      signals = []

      with_replaced_singleton_method(Process, :kill, ->(signal, pid) { signals << [ signal, pid ] }) do
        Hive::Commands::Uninstall.new(output: StringIO.new).send(:stop_foreground_bot)
      end

      assert_equal [ [ "TERM", 456 ] ], signals
    end
  end

  def test_stop_foreground_bot_tolerates_bare_scalar_pid_file_without_aborting
    # A corrupt/legacy bare-integer .bot.pid is valid YAML (parses to an
    # Integer). Indexing it with ["pid"] would raise TypeError; the guard
    # must degrade to a no-op so the rest of uninstall still runs.
    with_xdg_home do
      FileUtils.mkdir_p(Hive::Paths.state_home)
      File.write(File.join(Hive::Paths.state_home, ".bot.pid"), "12345\n")

      with_replaced_singleton_method(Process, :kill, ->(_s, _p) { raise "must not kill on a non-Hash pid file" }) do
        # Must not raise.
        Hive::Commands::Uninstall.new(output: StringIO.new).send(:stop_foreground_bot)
      end
    end
  end

  def test_uninstall_completes_when_bot_pid_file_is_corrupt
    # Regression: a malformed .bot.pid must not abort the whole uninstall
    # (it runs after deregister_daemon, so an unrescued raise would strand
    # the bot unit + skip config/data/symlink cleanup).
    with_xdg_home do
      FileUtils.mkdir_p(Hive::Paths.state_home)
      File.write(File.join(Hive::Paths.state_home, ".bot.pid"), "- not\n- a\n- hash\n")
      out = StringIO.new

      status = Hive::Commands::Uninstall.new(
        purge: true, output: out, runner: ->(_argv) { true }, host_os: "linux"
      ).call

      assert_equal 0, status, "uninstall must finish cleanly despite a corrupt bot pid file"
      assert_match(/core uninstall cleanup complete/, out.string)
    end
  end

  def test_stop_foreground_bot_ignores_stale_pid
    with_xdg_home do
      FileUtils.mkdir_p(Hive::Paths.state_home)
      File.write(File.join(Hive::Paths.state_home, ".bot.pid"),
                 { "pid" => 789, "started_at" => "2026-05-27T00:00:00Z" }.to_yaml)

      with_replaced_singleton_method(Process, :kill, ->(_signal, _pid) { raise Errno::ESRCH }) do
        # A dead/stale bot pid must be swallowed, not re-raised, so a
        # vanished bot never aborts the rest of the uninstall.
        Hive::Commands::Uninstall.new(output: StringIO.new).send(:stop_foreground_bot)
      end
    end
  end

  def test_stop_foreground_bot_warns_but_continues_on_eperm
    # EPERM means the bot is alive but owned by another uid. Unlike the
    # dead/corrupt cases this must NOT be a silent no-op: the operator's bot
    # may keep running against state we're about to delete, so it warns
    # (without aborting the destructive uninstall).
    with_xdg_home do
      FileUtils.mkdir_p(Hive::Paths.state_home)
      File.write(File.join(Hive::Paths.state_home, ".bot.pid"),
                 { "pid" => 999, "started_at" => "2026-05-27T00:00:00Z" }.to_yaml)
      out = StringIO.new

      with_replaced_singleton_method(Process, :kill, ->(_signal, _pid) { raise Errno::EPERM }) do
        Hive::Commands::Uninstall.new(output: out).send(:stop_foreground_bot)
      end

      assert_match(/bot pid 999 is alive but could not be signalled \(EPERM\)/, out.string)
    end
  end

  def test_macos_launch_agent_noops_when_plist_missing
    with_xdg_home do
      calls = []

      Hive::Commands::Uninstall.new(
        purge: true,
        output: StringIO.new,
        runner: ->(argv) { calls << argv; true },
        host_os: "darwin"
      ).call

      assert_equal [], calls
    end
  end

  def test_force_purge_state_preserves_collapsed_hive_home
    with_xdg_home do |dir|
      ENV["HIVE_HOME"] = File.join(dir, "collapsed")
      FileUtils.mkdir_p(File.join(Hive::Paths.state_home, "projects", "work"))
      File.write(Hive::Config.global_config_path, { "registered_projects" => [] }.to_yaml)

      Hive::Commands::Uninstall.new(
        purge: true,
        force_purge_state: true,
        output: StringIO.new,
        runner: ->(_argv) { true },
        host_os: "freebsd"
      ).call

      assert File.exist?(File.join(Hive::Paths.state_home, "projects", "work"))
    end
  end

  def test_interactive_cleanup_with_no_projects_skips_prompt
    with_xdg_home do
      out = StringIO.new
      input = StringIO.new("yes\n")

      Hive::Commands::Uninstall.new(
        input: input,
        output: out,
        runner: ->(_argv) { true },
        host_os: "freebsd"
      ).call

      assert_match(/preserving/, out.string)
      refute_match(/registered projects:/, out.string)
      assert_equal "yes\n", input.string[input.pos..]
    end
  end

  def test_purge_preserves_state_and_project_hive_state
    with_xdg_home do |dir|
      project = File.join(dir, "project")
      setup_install_tree(project)

      Hive::Commands::Uninstall.new(
        purge: true,
        output: StringIO.new,
        runner: ->(_argv) { true },
        host_os: "linux"
      ).call

      refute File.exist?(Hive::Paths.config_home)
      refute File.exist?(Hive::Paths.cache_home)
      refute File.exist?(File.join(Hive::Paths.data_home, "v#{Hive::VERSION}"))
      assert File.exist?(Hive::Paths.state_home)
      # Tighten the invariant: a regression that wipes `projects/work` but
      # leaves the parent `state_home` stub would slip past a bare-parent
      # check, so assert on the actual work payload.
      assert File.exist?(File.join(Hive::Paths.state_home, "projects", "work"))
      assert File.exist?(File.join(project, ".hive-state"))
    end
  end

  def test_force_purge_state_removes_accumulated_state_and_project_state
    with_xdg_home do |dir|
      project = File.join(dir, "project")
      setup_install_tree(project)

      Hive::Commands::Uninstall.new(
        purge: true,
        force_purge_state: true,
        output: StringIO.new,
        runner: ->(_argv) { true },
        host_os: "linux"
      ).call

      refute File.exist?(Hive::Paths.state_home)
      refute File.exist?(File.join(project, ".hive-state"))
    end
  end

  def test_hive_home_collapse_skips_config_cache_and_state_deletes
    # `with_xdg_home` (not the bare `with_tmp_dir`) is load-bearing here:
    # `Hive::Paths.bin_home` intentionally ignores HIVE_HOME, so without
    # the HOME / XDG_BIN_HOME isolation that `with_xdg_home` sets up,
    # `Uninstall#remove_user_symlinks` would resolve `bin_home` to the
    # real `~/.local/bin/` and unlink the user's actual hive/hv
    # symlinks during `rake test`. Every other Uninstall test in this
    # file uses `with_xdg_home` for that reason; this one is the lone
    # path that needs to override HIVE_HOME after entering the sandbox.
    with_xdg_home do |dir|
      ENV["HIVE_HOME"] = File.join(dir, "collapsed")
      FileUtils.mkdir_p(ENV.fetch("HIVE_HOME"))
      File.write(Hive::Config.global_config_path, { "registered_projects" => [] }.to_yaml)
      FileUtils.mkdir_p(File.join(Hive::Paths.state_home, "projects", "work"))

      out = StringIO.new
      Hive::Commands::Uninstall.new(
        purge: true,
        output: out,
        runner: ->(_argv) { true },
        host_os: "freebsd"
      ).call

      assert File.exist?(Hive::Paths.config_home)
      assert File.exist?(File.join(Hive::Paths.state_home, "projects", "work"))
      assert_match(/HIVE_HOME collapses/, out.string)
    end
  end

  def test_interactive_prompt_refusal_preserves_project_state
    with_xdg_home do |dir|
      project = File.join(dir, "project")
      setup_install_tree(project)

      Hive::Commands::Uninstall.new(
        input: StringIO.new("n\n"),
        output: StringIO.new,
        runner: ->(_argv) { true },
        host_os: "freebsd"
      ).call

      assert File.exist?(File.join(project, ".hive-state"))
    end
  end

  def test_interactive_prompt_acceptance_removes_project_state
    with_xdg_home do |dir|
      project = File.join(dir, "project")
      setup_install_tree(project)

      Hive::Commands::Uninstall.new(
        input: StringIO.new("yes\n"),
        output: StringIO.new,
        runner: ->(_argv) { true },
        host_os: "freebsd"
      ).call

      refute File.exist?(File.join(project, ".hive-state"))
    end
  end

  def test_safe_unlink_refuses_symlinked_systemd_unit
    with_xdg_home do
      unit = File.expand_path("~/.config/systemd/user/hive-daemon.service")
      target = File.join(Hive::Paths.cache_home, "target.service")
      FileUtils.mkdir_p(File.dirname(unit))
      FileUtils.mkdir_p(File.dirname(target))
      File.write(target, "unit\n")
      File.symlink(target, unit)
      out = StringIO.new

      Hive::Commands::Uninstall.new(
        purge: true,
        output: out,
        runner: ->(_argv) { true },
        host_os: "linux"
      ).call

      assert File.symlink?(unit)
      assert_match(/refusing to follow symlink/, out.string)
    end
  end

  def test_systemd_disable_failure_leaves_unit_in_place
    with_xdg_home do
      unit = File.expand_path("~/.config/systemd/user/hive-daemon.service")
      FileUtils.mkdir_p(File.dirname(unit))
      File.write(unit, "unit\n")
      out = StringIO.new

      Hive::Commands::Uninstall.new(
        purge: true,
        output: out,
        runner: ->(_argv) { false },
        host_os: "linux"
      ).call

      assert File.exist?(unit)
      assert_match(/leaving .* in place/, out.string)
    end
  end

  def test_systemd_daemon_reload_failure_is_reported
    with_xdg_home do
      unit = File.expand_path("~/.config/systemd/user/hive-daemon.service")
      FileUtils.mkdir_p(File.dirname(unit))
      File.write(unit, "unit\n")
      calls = []
      out = StringIO.new

      Hive::Commands::Uninstall.new(
        purge: true,
        output: out,
        runner: lambda do |argv|
          calls << argv
          argv != %w[systemctl --user daemon-reload]
        end,
        host_os: "linux"
      ).call

      refute File.exist?(unit)
      assert_includes calls, %w[systemctl --user daemon-reload]
      assert_match(/daemon-reload failed/, out.string)
    end
  end

  def test_deregister_unit_renders_stale_and_generic_boundary_failures
    out = StringIO.new
    command = Hive::Commands::Uninstall.new(output: out)
    installer = Object.new
    installer.define_singleton_method(:target_path) { "/tmp/hive-test.service" }
    results = [
      Hive::UserService::Result.new(
        :partial,
        operation: :remove,
        diagnostics: [ :stale_after_manager_change ]
      ),
      Hive::UserService::Result.new(
        :failed,
        operation: :remove,
        diagnostics: [ :remove_failed ]
      )
    ]
    installer.define_singleton_method(:remove!) { results.shift }

    2.times { command.send(:deregister_unit, installer) }

    assert_match(/changed while its service was being disabled/, out.string)
    assert_match(/could not remove .* leaving it in place/, out.string)
  end
end
