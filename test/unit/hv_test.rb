require "test_helper"
require "open3"
require "timeout"

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

  def test_self_recursion_guard_resolves_symlinks_via_realpath_rung
    assert_recursion_guard_holds(disabled_resolvers: [])
  end

  def test_self_recursion_guard_resolves_symlinks_via_ruby_rung
    assert_recursion_guard_holds(disabled_resolvers: %w[realpath])
  end

  def test_self_recursion_guard_resolves_symlinks_via_python_rung
    assert_recursion_guard_holds(disabled_resolvers: %w[realpath ruby])
  end

  def test_self_recursion_guard_resolves_symlinks_via_readlink_rung
    assert_recursion_guard_holds(disabled_resolvers: %w[realpath ruby python3])
  end

  def test_canonical_path_warns_when_all_resolvers_fail
    with_tmp_dir do |dir|
      fake_bin = write_failing_resolvers(dir, %w[realpath ruby python3 readlink])

      # A non-symlink override: with every resolver disabled, canonical_path
      # falls through to the raw-path rung. The override path differs from
      # the raw `hv` path, so the guard does not skip it and execs the
      # override — exercising the echo rung without risking a runaway.
      override = File.join(dir, "custom", "hive")
      FileUtils.mkdir_p(File.dirname(override))
      File.write(override, "#!/bin/sh\nif [ \"$1\" = \"--version\" ]; then echo 1.2.3; exit 0; fi\necho override:$1\n")
      FileUtils.chmod(0o755, override)

      out, err, status = capture_hv_with_timeout(
        {
          "HIVE_BIN_OVERRIDE" => override,
          "XDG_BIN_HOME" => File.join(dir, "empty-xdg"),
          "HOMEBREW_PREFIX" => File.join(dir, "empty-homebrew"),
          "PATH" => [ fake_bin, ENV.fetch("PATH", "") ].join(File::PATH_SEPARATOR)
        },
        "probe"
      )

      assert status.success?, err
      assert_equal "override:probe\n", out
      assert_includes err, "could not canonicalize",
                      "the raw-path fallthrough must emit a stderr diagnostic so a runaway is never silent"
    end
  end

  private

  def assert_recursion_guard_holds(disabled_resolvers:)
    with_tmp_dir do |dir|
      fake_bin = write_failing_resolvers(dir, disabled_resolvers)

      override = File.join(dir, "custom", "hive")
      FileUtils.mkdir_p(File.dirname(override))
      FileUtils.ln_s(HV_BIN, override)

      out, err, status = capture_hv_with_timeout(
        {
          "HIVE_BIN_OVERRIDE" => override,
          "XDG_BIN_HOME" => File.join(dir, "empty-xdg"),
          "HOMEBREW_PREFIX" => File.join(dir, "empty-homebrew"),
          "PATH" => [ fake_bin, ENV.fetch("PATH", "") ].join(File::PATH_SEPARATOR)
        },
        "probe"
      )

      assert_equal "", out
      assert_equal 127, status.exitstatus, err
      assert_includes err, "hive binary not found"
    end
  end

  def write_failing_resolvers(dir, names)
    fake_bin = File.join(dir, "bin")
    FileUtils.mkdir_p(fake_bin)
    names.each do |name|
      stub = File.join(fake_bin, name)
      File.write(stub, "#!/bin/sh\nexit 1\n")
      FileUtils.chmod(0o755, stub)
    end
    fake_bin
  end

  # Generous hang-detector budget. The `hv` shim should exit near-instantly;
  # this only fires on a real infinite-recursion hang. 2s was too tight under
  # loaded CI (bash startup + subprocess spawn), which caused spurious
  # Timeout::Error flakes — 30s detects a genuine hang while tolerating load.
  HV_HANG_TIMEOUT_SEC = 30

  def capture_hv_with_timeout(env, *args)
    Open3.popen3(env, HV_BIN, *args) do |stdin, stdout, stderr, wait_thread|
      stdin.close
      out_reader = Thread.new { stdout.read }
      err_reader = Thread.new { stderr.read }
      status = Timeout.timeout(HV_HANG_TIMEOUT_SEC) { wait_thread.value }
      [ out_reader.value, err_reader.value, status ]
    rescue Timeout::Error
      Process.kill("TERM", wait_thread.pid)
      Process.wait(wait_thread.pid)
      raise
    rescue Errno::ESRCH, Errno::ECHILD
      raise Timeout::Error, "hv did not exit"
    end
  end
end
