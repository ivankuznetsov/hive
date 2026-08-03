require "test_helper"
require "hive/commands/update"

class UpdateCommandTest < Minitest::Test
  include HiveTestHelper

  def test_brew_dry_run_prints_brew_upgrade
    out = StringIO.new
    Hive::Commands::Update.new(
      dry_run: true,
      output: out,
      channel: "brew",
      binary_resolver: -> { "/usr/local/bin/hive" }
    ).call

    assert_includes out.string, "channel: brew"
    assert_includes out.string, "brew upgrade #{Hive::Commands::Update::BREW_TAP}"
    assert_includes out.string, "post-update migration: /usr/local/bin/hive migrate --all"
  end

  def test_bash_dry_run_prints_installer
    out = StringIO.new
    Hive::Commands::Update.new(dry_run: true, output: out, channel: "bash").call

    assert_includes out.string, "channel: bash"
    assert_includes out.string, "curl -fsSL"
    assert_includes out.string, "install.sh"
    refute_match(/\|\s*bash/, out.string)
  end

  def test_bash_channel_downloads_installer_before_running
    with_tmp_dir do |dir|
      curl = File.join(dir, "curl")
      File.write(curl, "#!/bin/sh\n")
      FileUtils.chmod(0755, curl)
      captured = []

      Hive::Commands::Update.new(
        channel: "bash",
        env: { "PATH" => dir },
        runner: ->(argv) { captured << argv; true },
        binary_resolver: -> { "/usr/local/bin/hive" }
      ).call

      assert_equal "bash", captured[0][0]
      assert_equal "-c", captured[0][1]
      assert_includes captured[0][2], "curl -fsSL"
      assert_includes captured[0][2], '-o "$tmpdir/install.sh"'
      assert_includes captured[0][2], 'bash "$tmpdir/install.sh"'
      refute_match(/\|\s*bash/, captured[0][2])
      assert_equal [ "/usr/local/bin/hive", "migrate", "--all" ], captured[1]
    end
  end

  def test_bash_channel_preserves_prefix_from_install_marker
    with_xdg_home do |dir|
      prefix = File.join(dir, "prefix")
      marker_home = Hive::Paths.data_home
      FileUtils.mkdir_p(marker_home)
      File.write(File.join(marker_home, "install-channel"), "bash\n")
      File.write(File.join(marker_home, "install-prefix"), "#{prefix}\n")
      curl = File.join(dir, "curl")
      File.write(curl, "#!/bin/sh\n")
      FileUtils.chmod(0755, curl)
      captured = []

      Hive::Commands::Update.new(
        env: { "PATH" => dir },
        runner: ->(argv) { captured << argv; true },
        binary_resolver: -> { "/usr/local/bin/hive" }
      ).call

      assert_includes captured[0][2], "raw.githubusercontent.com/ivankuznetsov/hive/main/install.sh"
      assert_includes captured[0][2], "--prefix=#{Shellwords.escape(prefix)}"
      assert_equal [ "/usr/local/bin/hive", "migrate", "--all" ], captured[1]
    end
  end

  def test_dev_channel_prints_git_guidance
    out = StringIO.new
    Hive::Commands::Update.new(output: out, channel: "dev").call

    assert_includes out.string, "channel: dev"
    assert_includes out.string, "git pull && bundle install"
    assert_includes out.string, "hive migrate --all"
  end

  def test_aur_uses_yay_when_available
    with_tmp_dir do |dir|
      yay = File.join(dir, "yay")
      File.write(yay, "#!/bin/sh\n")
      FileUtils.chmod(0755, yay)
      captured = []

      Hive::Commands::Update.new(
        channel: "aur",
        env: { "PATH" => dir },
        runner: ->(argv) { captured << argv; true },
        binary_resolver: -> { "/usr/local/bin/hive" }
      ).call

      assert_equal [ yay, "-Syu", "hive-bin" ], captured[0]
      assert_equal [ "/usr/local/bin/hive", "migrate", "--all" ], captured[1]
    end
  end

  def test_aur_without_helper_exits_unavailable
    err = assert_raises(Hive::UnavailableError) do
      Hive::Commands::Update.new(channel: "aur", env: { "PATH" => "" }).call
    end
    assert_equal Hive::ExitCodes::UNAVAILABLE, err.exit_code
    assert_match(/install yay or paru/, err.message)
  end

  def test_aur_falls_back_to_paru_when_yay_missing
    with_tmp_dir do |dir|
      paru = File.join(dir, "paru")
      File.write(paru, "#!/bin/sh\n")
      FileUtils.chmod(0755, paru)
      captured = []

      Hive::Commands::Update.new(
        channel: "aur",
        env: { "PATH" => dir },
        runner: ->(argv) { captured << argv; true },
        binary_resolver: -> { "/usr/local/bin/hive" }
      ).call

      assert_equal [ paru, "-Syu", "hive-bin" ], captured[0]
      assert_equal [ "/usr/local/bin/hive", "migrate", "--all" ], captured[1]
    end
  end

  def test_unknown_channel_raises_config_error
    err = assert_raises(Hive::ConfigError) do
      Hive::Commands::Update.new(dry_run: true, channel: "tarball").call
    end

    assert_match(/unknown hive install channel \"tarball\"/, err.message)
  end

  def test_runner_enoent_is_wrapped_as_unavailable
    with_tmp_dir do |dir|
      brew = File.join(dir, "brew")
      File.write(brew, "#!/bin/sh\n")
      FileUtils.chmod(0755, brew)

      err = assert_raises(Hive::UnavailableError) do
        Hive::Commands::Update.new(
          channel: "brew",
          env: { "PATH" => dir },
          runner: ->(_argv) { raise Errno::ENOENT, "missing-brew" }
        ).call
      end

      assert_match(/hive update: No such file or directory/, err.message)
      assert_match(/missing-brew/, err.message)
    end
  end

  def test_brew_missing_helper_raises_unavailable
    err = assert_raises(Hive::UnavailableError) do
      Hive::Commands::Update.new(channel: "brew", env: { "PATH" => "" }).call
    end

    assert_match(/required helper 'brew' not found/, err.message)
  end

  def test_bash_missing_curl_raises_unavailable
    err = assert_raises(Hive::UnavailableError) do
      Hive::Commands::Update.new(channel: "bash", env: { "PATH" => "" }).call
    end

    assert_match(/required helper 'curl' not found/, err.message)
  end

  def test_nudge_command_per_channel
    %w[brew aur bash].each do |channel|
      assert_equal "hive update", Hive::Commands::Update.nudge_command(channel)
    end
    assert_nil Hive::Commands::Update.nudge_command("dev")
  end

  def test_successful_update_reports_automatic_migration_status
    with_update_helper("brew") do |env|
      out = StringIO.new
      calls = []

      result = Hive::Commands::Update.new(
        channel: "brew",
        output: out,
        env: env,
        runner: ->(argv) { calls << argv; true },
        binary_resolver: -> { "/opt/homebrew/bin/hive" }
      ).call

      assert_equal 0, result
      assert_equal(
        [
          [ "brew", "upgrade", Hive::Commands::Update::BREW_TAP ],
          [ "/opt/homebrew/bin/hive", "migrate", "--all" ]
        ],
        calls
      )
      assert_includes out.string, "hive: update: running brew updater"
      assert_includes out.string, "hive: update: installed; starting automatic migration"
      assert_includes out.string, "hive: update: complete; automatic migration succeeded"
    end
  end

  def test_failed_updater_does_not_start_migration
    with_update_helper("brew") do |env|
      out = StringIO.new
      calls = []

      error = assert_raises(Hive::Error) do
        Hive::Commands::Update.new(
          channel: "brew",
          output: out,
          env: env,
          runner: ->(argv) { calls << argv; false },
          binary_resolver: -> { "/usr/local/bin/hive" }
        ).call
      end

      assert_equal [ [ "brew", "upgrade", Hive::Commands::Update::BREW_TAP ] ], calls
      assert_match(/updater failed/, error.message)
      assert_match(/automatic migration was not started/, error.message)
    end
  end

  def test_failed_automatic_migration_has_human_readable_recovery
    with_update_helper("brew") do |env|
      out = StringIO.new
      calls = []

      error = assert_raises(Hive::Error) do
        Hive::Commands::Update.new(
          channel: "brew",
          output: out,
          env: env,
          runner: lambda { |argv|
            calls << argv
            calls.length == 1
          },
          binary_resolver: -> { "/usr/local/bin/hive" }
        ).call
      end

      assert_equal [ "/usr/local/bin/hive", "migrate", "--all" ], calls.last
      assert_match(/automatic migration failed/, error.message)
      assert_match(%r{/usr/local/bin/hive migrate --all}, error.message)
      assert_includes out.string, "starting automatic migration"
      refute_includes out.string, "automatic migration succeeded"
    end
  end

  def test_failed_automatic_migration_reports_the_exit_status
    with_update_helper("brew") do |env|
      calls = 0

      error = assert_raises(Hive::Error) do
        Hive::Commands::Update.new(
          channel: "brew",
          env: env,
          runner: lambda { |_argv|
            calls += 1
            Hive::Commands::Update::CommandResult.new(
              success: calls == 1,
              exitstatus: calls == 1 ? 0 : 23
            )
          },
          binary_resolver: -> { "/usr/local/bin/hive" }
        ).call
      end

      assert_match(/automatic migration failed \(exit 23\)/, error.message)
    end
  end

  def test_missing_updated_binary_has_human_readable_recovery
    with_update_helper("brew") do |env|
      error = assert_raises(Hive::UnavailableError) do
        Hive::Commands::Update.new(
          channel: "brew",
          env: env,
          runner: ->(_argv) { true },
          binary_resolver: -> { nil }
        ).call
      end

      assert_match(/update installed but the updated Hive executable could not be found/, error.message)
      assert_match(/run `hive migrate --all`/, error.message)
    end
  end

  def test_updated_binary_resolution_prefers_a_fresh_path_lookup
    with_tmp_dir do |dir|
      invoked = File.join(dir, "old", "hive")
      fresh = File.join(dir, "current", "hive")
      [ invoked, fresh ].each do |binary|
        FileUtils.mkdir_p(File.dirname(binary))
        File.write(binary, "#!/bin/sh\n")
        FileUtils.chmod(0o755, binary)
      end

      with_replaced_singleton_method(Hive::InvokedBinary, :path, ->(env:) { invoked }) do
        with_replaced_singleton_method(Hive::InvokedBinary, :which, ->(name, env:) { fresh if name == "hive" }) do
          resolved = Hive::Commands::Update.new.send(:resolve_updated_binary)
          assert_equal fresh, resolved
        end
      end
    end
  end

  def test_updated_binary_resolution_falls_back_to_the_invoked_binary
    with_tmp_dir do |dir|
      invoked = File.join(dir, "hv")
      File.write(invoked, "#!/bin/sh\n")
      FileUtils.chmod(0o755, invoked)

      with_replaced_singleton_method(Hive::InvokedBinary, :path, ->(env:) { invoked }) do
        with_replaced_singleton_method(Hive::InvokedBinary, :which, ->(_name, env:) { nil }) do
          resolved = Hive::Commands::Update.new.send(:resolve_updated_binary)
          assert_equal invoked, resolved
        end
      end
    end
  end

  def test_real_command_runner_preserves_the_exit_status
    with_tmp_dir do |dir|
      command = File.join(dir, "fail")
      File.write(command, "#!/bin/sh\nexit 23\n")
      FileUtils.chmod(0o755, command)

      result = Hive::Commands::Update.new.send(:run_command, [ command ])

      refute result.success?
      assert_equal 23, result.exitstatus
    end
  end

  private

  def with_update_helper(name)
    with_tmp_dir do |dir|
      helper = File.join(dir, name)
      File.write(helper, "#!/bin/sh\n")
      FileUtils.chmod(0o755, helper)
      yield({ "PATH" => dir })
    end
  end
end
