require "test_helper"
require "open3"
require "rbconfig"
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

  def test_slow_candidate_is_bounded_when_timeout_binary_is_absent
    with_tmp_dir do |dir|
      slow = File.join(dir, "custom", "hive")
      FileUtils.mkdir_p(File.dirname(slow))
      File.write(slow, <<~SH)
        #!/bin/sh
        if [ "$1" = "--version" ]; then exec #{RbConfig.ruby} -e 'sleep 60'; fi
        echo slow:$1
      SH
      FileUtils.chmod(0o755, slow)

      bash_env = File.join(dir, "bash-env")
      File.write(bash_env, <<~SH)
        command() {
          if [ "$1" = "-v" ] && [ "${2:-}" = "timeout" ]; then return 1; fi
          builtin command "$@"
        }

        sleep() {
          case "${1:-}" in
            5|1) builtin command sleep 0.1 ;;
            *) builtin command sleep "$@" ;;
          esac
        }
      SH

      xdg_bin = File.join(dir, "xdg-bin")
      FileUtils.mkdir_p(xdg_bin)
      File.write(File.join(xdg_bin, "hive"), <<~SH)
        #!/bin/sh
        if [ "$1" = "--version" ]; then echo "2.3.4"; exit 0; fi
        echo xdg:$1
      SH
      FileUtils.chmod(0o755, File.join(xdg_bin, "hive"))

      out, err, status = capture_hv_with_timeout(
        {
          "HIVE_BIN_OVERRIDE" => slow,
          "XDG_BIN_HOME" => xdg_bin,
          "HOMEBREW_PREFIX" => File.join(dir, "empty-homebrew"),
          "BASH_ENV" => bash_env
        },
        "probe"
      )

      assert status.success?, err
      assert_equal "xdg:probe\n", out
      refute_includes out, "slow:probe"
    end
  end

  def test_timeout_probe_uses_kill_after_when_supported
    with_tmp_dir do |dir|
      override = File.join(dir, "custom", "hive")
      FileUtils.mkdir_p(File.dirname(override))
      File.write(override, <<~SH)
        #!/bin/sh
        if [ "$1" = "--version" ]; then echo "1.2.3"; exit 0; fi
        echo override:$1
      SH
      FileUtils.chmod(0o755, override)

      log = File.join(dir, "timeout.log")
      fake_bin = File.join(dir, "bin")
      FileUtils.mkdir_p(fake_bin)
      File.write(File.join(fake_bin, "timeout"), <<~SH)
        #!/bin/sh
        printf '%s\\n' "$*" >> "#{log}"
        if [ "$1" != "-k" ]; then
          exit 125
        fi
        shift 2
        shift
        exec "$@"
      SH
      FileUtils.chmod(0o755, File.join(fake_bin, "timeout"))

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
      lines = File.readlines(log, chomp: true)
      assert_includes lines, "-k 1 1 true"
      assert_includes lines, "-k 1 5 #{override} --version"
    end
  end

  def test_timeout_probe_falls_back_when_kill_after_is_unsupported
    with_tmp_dir do |dir|
      override = File.join(dir, "custom", "hive")
      FileUtils.mkdir_p(File.dirname(override))
      File.write(override, <<~SH)
        #!/bin/sh
        if [ "$1" = "--version" ]; then echo "1.2.3"; exit 0; fi
        echo override:$1
      SH
      FileUtils.chmod(0o755, override)

      log = File.join(dir, "timeout.log")
      fake_bin = File.join(dir, "bin")
      FileUtils.mkdir_p(fake_bin)
      File.write(File.join(fake_bin, "timeout"), <<~SH)
        #!/bin/sh
        printf '%s\\n' "$*" >> "#{log}"
        if [ "$1" = "-k" ]; then
          exit 125
        fi
        shift
        exec "$@"
      SH
      FileUtils.chmod(0o755, File.join(fake_bin, "timeout"))

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
      lines = File.readlines(log, chomp: true)
      assert_includes lines, "-k 1 1 true"
      assert_includes lines, "5 #{override} --version"
    end
  end

  def test_timed_out_probe_tree_is_group_killed_when_timeout_binary_is_absent
    with_tmp_dir do |dir|
      pidfile = File.join(dir, "probe-child.pid")

      # A wrapper candidate that forks a long-lived child WITHOUT `exec`,
      # records its PID, then blocks. On the no-`timeout` fallback path the
      # watchdog must group-kill the probe: TERMing only the wrapper PID would
      # orphan this child (a stand-in for a JVM/helper), and repeated probes
      # would accrete stray processes. The watchdog launches the probe under
      # monitor mode so a negative-PID kill reaches the whole tree.
      wrapper = File.join(dir, "custom", "hive")
      FileUtils.mkdir_p(File.dirname(wrapper))
      File.write(wrapper, <<~SH)
        #!/bin/sh
        if [ "$1" = "--version" ]; then
          #{RbConfig.ruby} -e 'sleep 60' &
          echo "$!" > "#{pidfile}"
          wait
          exit 0
        fi
        echo wrapper:$1
      SH
      FileUtils.chmod(0o755, wrapper)

      bash_env = File.join(dir, "bash-env")
      File.write(bash_env, <<~SH)
        command() {
          if [ "$1" = "-v" ] && [ "${2:-}" = "timeout" ]; then return 1; fi
          builtin command "$@"
        }

        sleep() {
          case "${1:-}" in
            5|1) builtin command sleep 0.1 ;;
            *) builtin command sleep "$@" ;;
          esac
        }
      SH

      xdg_bin = File.join(dir, "xdg-bin")
      FileUtils.mkdir_p(xdg_bin)
      File.write(File.join(xdg_bin, "hive"), <<~SH)
        #!/bin/sh
        if [ "$1" = "--version" ]; then echo "2.3.4"; exit 0; fi
        echo xdg:$1
      SH
      FileUtils.chmod(0o755, File.join(xdg_bin, "hive"))

      out, err, status = capture_hv_with_timeout(
        {
          "HIVE_BIN_OVERRIDE" => wrapper,
          "XDG_BIN_HOME" => xdg_bin,
          "HOMEBREW_PREFIX" => File.join(dir, "empty-homebrew"),
          "BASH_ENV" => bash_env
        },
        "probe"
      )

      assert status.success?, err
      assert_equal "xdg:probe\n", out, "hv must fall through the hung wrapper to the good candidate"

      child_pid = Integer(File.read(pidfile).strip)
      refute probe_child_alive?(child_pid),
             "the watchdog must group-kill the probe so a fork-without-exec child is not orphaned"
    ensure
      reap_probe_child(pidfile)
    end
  end

  def test_term_ignoring_probe_helper_is_swept_when_wrapper_exits_on_term
    with_tmp_dir do |dir|
      pidfile = File.join(dir, "probe-child.pid")

      # The sibling of the group-kill case: a wrapper that exits on TERM while
      # leaving a TERM-ignoring helper alive. When the watchdog TERMs the group,
      # the wrapper exits and releases the `wait "$pid"` in `probe_version`,
      # which tears the watchdog down BEFORE it reaches its KILL escalation. The
      # helper would survive as an orphan unless `probe_version` sweeps the
      # probe's process group itself after teardown.
      wrapper = File.join(dir, "custom", "hive")
      FileUtils.mkdir_p(File.dirname(wrapper))
      File.write(wrapper, <<~SH)
        #!/bin/sh
        if [ "$1" = "--version" ]; then
          trap 'exit 0' TERM
          ( trap '' TERM; exec #{RbConfig.ruby} -e 'sleep 60' ) &
          echo "$!" > "#{pidfile}"
          wait
          exit 0
        fi
        echo wrapper:$1
      SH
      FileUtils.chmod(0o755, wrapper)

      # Stub only the watchdog's 5s arming delay so the test is fast. The 1s KILL
      # escalation stays real: that guarantees the wrapper's TERM-exit reliably
      # tears the watchdog down before it can escalate, reproducing exactly the
      # path the post-teardown sweep must cover (a stubbed `sleep 1` would race
      # the watchdog's own KILL against ours and mask a regression).
      bash_env = File.join(dir, "bash-env")
      File.write(bash_env, <<~SH)
        command() {
          if [ "$1" = "-v" ] && [ "${2:-}" = "timeout" ]; then return 1; fi
          builtin command "$@"
        }

        sleep() {
          case "${1:-}" in
            5) builtin command sleep 0.1 ;;
            *) builtin command sleep "$@" ;;
          esac
        }
      SH

      xdg_bin = File.join(dir, "xdg-bin")
      FileUtils.mkdir_p(xdg_bin)
      File.write(File.join(xdg_bin, "hive"), <<~SH)
        #!/bin/sh
        if [ "$1" = "--version" ]; then echo "2.3.4"; exit 0; fi
        echo xdg:$1
      SH
      FileUtils.chmod(0o755, File.join(xdg_bin, "hive"))

      out, err, status = capture_hv_with_timeout(
        {
          "HIVE_BIN_OVERRIDE" => wrapper,
          "XDG_BIN_HOME" => xdg_bin,
          "HOMEBREW_PREFIX" => File.join(dir, "empty-homebrew"),
          "BASH_ENV" => bash_env
        },
        "probe"
      )

      assert status.success?, err
      assert_equal "xdg:probe\n", out, "hv must fall through the hung wrapper to the good candidate"

      child_pid = Integer(File.read(pidfile).strip)
      refute probe_child_alive?(child_pid),
             "probe_version must sweep the probe's process group so a TERM-ignoring helper is not orphaned"
    ensure
      reap_probe_child(pidfile)
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

  # Poll briefly for the orphan to disappear: after the watchdog group-kills
  # the probe, the child is reparented to the subreaper/init and reaped, so
  # `kill(0)` flips to ESRCH. Polling absorbs that small teardown window
  # without a fixed sleep.
  def probe_child_alive?(pid)
    20.times do
      Process.kill(0, pid)
      sleep 0.1
    end
    true
  rescue Errno::ESRCH
    false
  rescue Errno::EPERM
    # PID was recycled into a process we don't own — treat as gone.
    false
  end

  def reap_probe_child(pidfile)
    pid = Integer(File.read(pidfile).strip)
    Process.kill("KILL", pid)
  rescue StandardError
    nil
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
