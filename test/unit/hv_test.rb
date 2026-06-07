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
      File.write(override, "#!/bin/sh\necho override:$1\n")
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

  def test_implicit_candidate_with_apache_version_is_skipped
    with_tmp_dir do |dir|
      xdg_hive = File.join(dir, "xdg", "hive")
      brew_hive = File.join(dir, "brew", "bin", "hive")
      FileUtils.mkdir_p(File.dirname(xdg_hive))
      FileUtils.mkdir_p(File.dirname(brew_hive))
      File.write(xdg_hive, <<~SH)
        #!/bin/sh
        if [ "${1:-}" = "--version" ]; then
          echo "Hive 3.1.3"
          exit 0
        fi
        echo apache:$1
      SH
      File.write(brew_hive, <<~SH)
        #!/bin/sh
        if [ "${1:-}" = "--version" ]; then
          echo "0.2.0"
          exit 0
        fi
        echo brew:$1
      SH
      FileUtils.chmod(0o755, xdg_hive)
      FileUtils.chmod(0o755, brew_hive)

      out, err, status = Open3.capture3(
        {
          "HIVE_BIN_OVERRIDE" => nil,
          "XDG_BIN_HOME" => File.dirname(xdg_hive),
          "HOMEBREW_PREFIX" => File.dirname(File.dirname(brew_hive))
        },
        HV_BIN,
        "probe"
      )

      assert status.success?, err
      assert_equal "brew:probe\n", out
    end
  end
end
