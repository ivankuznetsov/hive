require "test_helper"
require "open3"

class HvTest < Minitest::Test
  include HiveTestHelper

  HV_BIN = File.expand_path("../../bin/hv", __dir__)

  def test_unsafe_apache_hive_paths_are_not_implicit_candidates
    body = File.read(HV_BIN)

    refute_includes body, '"/usr/bin/hive"'
    refute_includes body, '"/opt/hive/bin/hive"'
    refute_includes body, "/opt/hive/bin"
  end

  def test_hive_bin_override_can_point_at_custom_install_location
    with_tmp_dir do |dir|
      override = File.join(dir, "custom", "hive")
      FileUtils.mkdir_p(File.dirname(override))
      File.write(override, <<~SH)
        #!/bin/sh
        if [ "${1:-}" = "--version" ]; then
          echo 1.2.3
          exit 0
        fi
        echo override:$1
      SH
      FileUtils.chmod(0o755, override)

      out, err, status = Open3.capture3(
        {
          "HIVE_BIN_OVERRIDE" => override,
          "XDG_BIN_HOME" => File.join(dir, "empty-xdg"),
          "HOMEBREW_PREFIX" => File.join(dir, "empty-homebrew")
        },
        HV_BIN,
        "probe"
      )

      assert status.success?, err
      assert_equal "override:probe\n", out
    end
  end

  def test_apache_style_xdg_candidate_is_skipped_for_next_valid_hive_cli
    with_tmp_dir do |dir|
      xdg_home = File.join(dir, "xdg-bin")
      homebrew_prefix = File.join(dir, "homebrew")
      apache = File.join(xdg_home, "hive")
      real_hive = File.join(homebrew_prefix, "bin", "hive")

      FileUtils.mkdir_p(xdg_home)
      File.write(apache, <<~SH)
        #!/bin/sh
        if [ "${1:-}" = "--version" ]; then
          echo "Hive 4.0.0"
          exit 0
        fi
        echo apache:$1
      SH
      FileUtils.chmod(0o755, apache)

      FileUtils.mkdir_p(File.dirname(real_hive))
      File.write(real_hive, <<~SH)
        #!/bin/sh
        if [ "${1:-}" = "--version" ]; then
          echo 1.2.3
          exit 0
        fi
        echo real:$1
      SH
      FileUtils.chmod(0o755, real_hive)

      out, err, status = Open3.capture3(
        {
          "XDG_BIN_HOME" => xdg_home,
          "HOMEBREW_PREFIX" => homebrew_prefix
        },
        HV_BIN,
        "probe"
      )

      assert status.success?, err
      assert_equal "real:probe\n", out
    end
  end
end
