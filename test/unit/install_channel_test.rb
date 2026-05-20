require "test_helper"
require "rbconfig"
require "hive/install_channel"

class InstallChannelTest < Minitest::Test
  include HiveTestHelper

  def test_write_and_read_marker
    with_tmp_dir do |dir|
      path = File.join(dir, "install-channel")
      Hive::InstallChannel.write("bash", path: path)
      assert_equal "bash", Hive::InstallChannel.read(path)
    end
  end

  def test_rejects_unknown_channel
    err = assert_raises(Hive::ConfigError) do
      Hive::InstallChannel.write("pkgsrc", path: "/tmp/unused")
    end
    assert_match(/unknown hive install channel/, err.message)
  end

  def test_detect_fails_closed_on_corrupt_marker
    with_tmp_dir do |dir|
      corrupt = File.join(dir, "corrupt")
      fallback = File.join(dir, "fallback")
      File.write(corrupt, "pkgsrc\n")
      File.write(fallback, "bash\n")

      err = assert_raises(Hive::ConfigError) do
        Hive::InstallChannel.detect(marker_paths: [ corrupt, fallback ])
      end
      assert_match(/invalid install-channel marker/, err.message)
    end
  end

  def test_detect_uses_first_existing_marker
    with_tmp_dir do |dir|
      missing = File.join(dir, "missing")
      brew = File.join(dir, "brew")
      aur = File.join(dir, "aur")
      File.write(brew, "brew\n")
      File.write(aur, "aur\n")

      assert_equal "brew", Hive::InstallChannel.detect(marker_paths: [ missing, brew, aur ])
    end
  end

  def test_detect_falls_back_to_dev
    with_tmp_dir do |dir|
      assert_equal "dev", Hive::InstallChannel.detect(marker_paths: [ File.join(dir, "missing") ])
    end
  end

  def test_detected_prefix_reads_sidecar_for_first_valid_marker
    with_tmp_dir do |dir|
      marker = File.join(dir, "install-channel")
      File.write(marker, "bash\n")
      File.write(File.join(dir, "install-prefix"), "/opt/hive\n")

      assert_equal "/opt/hive", Hive::InstallChannel.detected_prefix(marker_paths: [ marker ])
    end
  end

  # Exercise the prod resolver `default_marker_paths` directly. Tests
  # that injected marker_paths previously skipped this branch — a
  # regression to the OS/Homebrew probe logic could silently return
  # `dev` without anything catching it.
  def test_default_marker_paths_includes_xdg_marker
    paths = Hive::InstallChannel.default_marker_paths
    assert_includes paths, Hive::InstallChannel.marker_path,
                    "default probes must include the canonical XDG marker_path"
    # On non-macOS hosts the brew probes must not appear — preventing
    # a stray HOMEBREW_PREFIX or /usr/local marker from hijacking
    # the install channel.
    unless RbConfig::CONFIG["host_os"] =~ /darwin/i
      assert paths.none? { |p| p.include?("/opt/homebrew/share/hive") },
             "non-macOS hosts must not probe /opt/homebrew markers"
    end
  end
end
