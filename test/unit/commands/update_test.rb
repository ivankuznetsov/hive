require "test_helper"
require "hive/commands/update"

class UpdateCommandTest < Minitest::Test
  include HiveTestHelper

  def test_brew_dry_run_prints_brew_upgrade
    out = StringIO.new
    Hive::Commands::Update.new(dry_run: true, output: out, channel: "brew").call

    assert_includes out.string, "channel: brew"
    assert_includes out.string, "brew upgrade ivankuznetsov/hive/hive"
  end

  def test_bash_dry_run_prints_installer
    out = StringIO.new
    Hive::Commands::Update.new(dry_run: true, output: out, channel: "bash").call

    assert_includes out.string, "curl -fsSL"
    assert_includes out.string, "install.sh"
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
end
