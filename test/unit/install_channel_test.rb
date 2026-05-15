require "test_helper"
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
end
