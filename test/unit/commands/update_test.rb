require "test_helper"
require "hive/commands/update"

class UpdateCommandTest < Minitest::Test
  include HiveTestHelper

  def test_brew_dry_run_prints_brew_upgrade
    out = StringIO.new
    Hive::Commands::Update.new(dry_run: true, output: out, channel: "brew").call

    assert_includes out.string, "channel: brew"
    assert_includes out.string, "brew upgrade #{Hive::Commands::Update::BREW_TAP}"
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
      captured = nil

      Hive::Commands::Update.new(
        channel: "bash",
        env: { "PATH" => dir },
        runner: ->(argv) { captured = argv }
      ).call

      assert_equal "bash", captured[0]
      assert_equal "-c", captured[1]
      assert_includes captured[2], "curl -fsSL"
      assert_includes captured[2], '-o "$tmpdir/install.sh"'
      assert_includes captured[2], 'bash "$tmpdir/install.sh"'
      refute_match(/\|\s*bash/, captured[2])
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
      captured = nil

      Hive::Commands::Update.new(
        env: { "PATH" => dir },
        runner: ->(argv) { captured = argv }
      ).call

      assert_includes captured[2], "raw.githubusercontent.com/ivankuznetsov/hive/main/install.sh"
      assert_includes captured[2], "--prefix=#{Shellwords.escape(prefix)}"
    end
  end

  def test_dev_channel_prints_git_guidance
    out = StringIO.new
    Hive::Commands::Update.new(output: out, channel: "dev").call

    assert_includes out.string, "channel: dev"
    assert_includes out.string, "git pull && bundle install"
  end

  def test_aur_uses_yay_when_available
    with_tmp_dir do |dir|
      yay = File.join(dir, "yay")
      File.write(yay, "#!/bin/sh\n")
      FileUtils.chmod(0755, yay)
      captured = nil

      Hive::Commands::Update.new(
        channel: "aur",
        env: { "PATH" => dir },
        runner: ->(argv) { captured = argv }
      ).call

      assert_equal [ yay, "-Syu", "hive-bin" ], captured
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
      captured = nil

      Hive::Commands::Update.new(
        channel: "aur",
        env: { "PATH" => dir },
        runner: ->(argv) { captured = argv }
      ).call

      assert_equal [ paru, "-Syu", "hive-bin" ], captured
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
end
