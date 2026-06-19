require "test_helper"
require "hive/commands/init/capture_tooling_installer"

class CaptureToolingInstallerTest < Minitest::Test
  FakeStatus = Struct.new(:ok) do
    def success?
      ok
    end
  end

  def installer_with_commands(*commands)
    available = commands.to_h { |name| [ name, name ] }
    Hive::Commands::Init::CaptureToolingInstaller.new(
      probe: ->(name) { available[name] }
    )
  end

  def test_detection_prefers_pacman_over_apt
    installer = installer_with_commands("pacman", "apt-get", "sudo")

    assert_equal :pacman, installer.package_manager.name
  end

  def test_brew_install_uses_no_sudo
    installer = installer_with_commands("brew", "sudo")
    seen = nil

    result = installer.install!(
      missing: %w[ffmpeg asciinema],
      runner: ->(argv) {
        seen = argv
        FakeStatus.new(true)
      }
    )

    assert_equal :installed, result
    assert_equal %w[brew install ffmpeg asciinema], seen
    refute_includes seen, "sudo"
    assert_equal "brew install ffmpeg asciinema", installer.command_for(missing: %w[ffmpeg asciinema])
  end

  def test_pacman_install_prefixes_sudo_and_only_missing_packages
    installer = installer_with_commands("pacman", "sudo")
    seen = nil

    result = installer.install!(
      missing: [ "asciinema" ],
      runner: ->(argv) {
        seen = argv
        FakeStatus.new(true)
      }
    )

    assert_equal :installed, result
    assert_equal %w[sudo pacman -S --needed --noconfirm asciinema], seen
    refute_includes seen, "ffmpeg"
  end

  def test_apt_install_prefixes_sudo
    installer = installer_with_commands("apt-get", "sudo")
    seen = nil

    result = installer.install!(
      missing: [ "ffmpeg" ],
      runner: ->(argv) {
        seen = argv
        true
      }
    )

    assert_equal :installed, result
    assert_equal %w[sudo apt-get install -y ffmpeg], seen
  end

  def test_no_supported_package_manager_returns_unsupported_with_manual_command
    installer = installer_with_commands("sudo")

    assert_nil installer.package_manager
    assert_equal :unsupported, installer.install!(missing: %w[ffmpeg], runner: ->(_argv) { true })
    assert_match(/ffmpeg/, installer.command_for(missing: %w[ffmpeg]))
  end

  def test_runner_failure_returns_failed_without_raising
    installer = installer_with_commands("pacman", "sudo")

    result = installer.install!(
      missing: %w[ffmpeg],
      runner: ->(_argv) { FakeStatus.new(false) }
    )

    assert_equal :failed, result
    assert_equal "sudo pacman -S --needed --noconfirm ffmpeg", installer.command_for(missing: %w[ffmpeg])
  end

  def test_runner_exception_returns_failed
    installer = installer_with_commands("pacman", "sudo")

    result = installer.install!(
      missing: %w[ffmpeg],
      runner: ->(_argv) { raise SystemCallError, "boom" }
    )

    assert_equal :failed, result
  end

  def test_command_for_only_includes_missing_package
    installer = installer_with_commands("brew")

    assert_equal "brew install asciinema", installer.command_for(missing: [ "asciinema" ])
  end
end
