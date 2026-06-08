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
        if [ "$1" = "--version" ]; then echo "1.2.3"; exit 0; fi
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

  def test_skips_executable_hive_candidate_without_bare_semver_version
    with_tmp_dir do |dir|
      bin = File.join(dir, "bin")
      FileUtils.mkdir_p(bin)
      File.write(File.join(bin, "hive"), <<~SH)
        #!/bin/sh
        if [ "$1" = "--version" ]; then echo "Hive 4.0.0"; exit 0; fi
        echo wrong:$1
      SH
      FileUtils.chmod(0o755, File.join(bin, "hive"))

      out, err, status = Open3.capture3(
        {
          "HIVE_BIN_OVERRIDE" => "",
          "XDG_BIN_HOME" => bin,
          "HOMEBREW_PREFIX" => File.join(dir, "empty-homebrew"),
          "HOME" => dir
        },
        HV_BIN,
        "probe"
      )

      assert_equal "", out
      refute status.success?
      assert_includes err, "HIVE_BIN_OVERRIDE"
      refute_includes out, "wrong:probe"
    end
  end

  def test_hive_bin_override_works_when_home_and_xdg_bin_home_are_unset
    with_tmp_dir do |dir|
      override = File.join(dir, "custom", "hive")
      FileUtils.mkdir_p(File.dirname(override))
      File.write(override, "#!/bin/sh\nif [ \"$1\" = \"--version\" ]; then echo 1.2.3; exit 0; fi\necho override:$1\n")
      FileUtils.chmod(0o755, override)

      out, err, status = Open3.capture3(
        {
          "HOME" => nil,
          "HIVE_BIN_OVERRIDE" => override,
          "XDG_BIN_HOME" => nil,
          "HOMEBREW_PREFIX" => File.join(dir, "empty-homebrew")
        },
        HV_BIN,
        "probe"
      )

      assert status.success?, err
      assert_equal "override:probe\n", out
    end
  end
end
