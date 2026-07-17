require "test_helper"
require "hive/agent_profile"

class AgentProfileTest < Minitest::Test
  include HiveTestHelper

  FAKE_BIN = File.expand_path("../fixtures/fake-claude", __dir__)

  def setup
    Hive::AgentProfile.reset_version_cache!
    @prev_bin = ENV["HIVE_CLAUDE_BIN"]
    ENV["HIVE_CLAUDE_BIN"] = FAKE_BIN
  end

  def teardown
    ENV["HIVE_CLAUDE_BIN"] = @prev_bin
    ENV.delete("HIVE_FAKE_CLAUDE_VERSION")
    Hive::AgentProfile.reset_version_cache!
  end

  def make_profile(overrides = {})
    defaults = {
      name: :test,
      bin_default: "claude",
      env_bin_override_key: "HIVE_CLAUDE_BIN",
      headless_flag: "-p",
      version_flag: "--version",
      skill_syntax_format: "/%{skill}",
      status_detection_mode: :state_file_marker
    }
    Hive::AgentProfile.new(**defaults.merge(overrides))
  end

  def test_freezes_at_construction
    profile = make_profile
    assert profile.frozen?
  end

  def test_rejects_unknown_prompt_style
    error = assert_raises(ArgumentError) do
      make_profile(prompt_style: :shell_interpolation)
    end

    assert_includes error.message, "unknown prompt_style"
  end

  def test_initial_context_reserve_defaults_to_zero_and_must_be_non_negative
    assert_equal 0, make_profile.initial_context_tokens

    error = assert_raises(ArgumentError) do
      make_profile(initial_context_tokens: -1)
    end
    assert_includes error.message, "non-negative Integer"
  end

  def test_bin_uses_env_override_when_set
    profile = make_profile(bin_default: "/nonexistent/claude", env_bin_override_key: "HIVE_CLAUDE_BIN")
    assert_equal FAKE_BIN, profile.bin
  end

  def test_bin_falls_back_to_default_when_env_empty
    ENV["HIVE_CLAUDE_BIN"] = ""
    profile = make_profile(bin_default: "default-claude", env_bin_override_key: "HIVE_CLAUDE_BIN")
    assert_equal "default-claude", profile.bin
  end

  def test_bin_falls_back_to_default_when_no_override_key
    ENV.delete("HIVE_FAKE_NO_KEY")
    profile = make_profile(bin_default: "fallback", env_bin_override_key: nil)
    assert_equal "fallback", profile.bin
  end

  def test_check_version_passes_when_above_minimum
    profile = make_profile(min_version: "1.0.0")
    ENV["HIVE_FAKE_CLAUDE_VERSION"] = "2.0.0"
    assert_equal "2.0.0", profile.check_version!
  end

  def test_check_version_passes_when_no_minimum_set
    profile = make_profile(min_version: nil)
    ENV["HIVE_FAKE_CLAUDE_VERSION"] = "0.0.1"
    assert_equal "0.0.1", profile.check_version!
  end

  def test_check_version_raises_when_below_minimum
    profile = make_profile(min_version: "5.0.0")
    ENV["HIVE_FAKE_CLAUDE_VERSION"] = "1.0.0"
    err = assert_raises(Hive::AgentError) { profile.check_version! }
    assert_match(/below minimum/, err.message)
  end

  def test_check_version_raises_when_binary_not_runnable
    profile = make_profile(bin_default: "/this/does/not/exist", env_bin_override_key: nil)
    err = assert_raises(Hive::AgentError) { profile.check_version! }
    assert_match(/not runnable/, err.message)
  end

  def test_check_version_raises_when_headless_unsupported
    profile = make_profile(headless_supported: false)
    err = assert_raises(Hive::AgentError) { profile.check_version! }
    assert_match(/not headless-supported/, err.message)
  end

  def test_check_version_raises_when_version_check_times_out
    with_tmp_dir do |dir|
      binary = File.join(dir, "hung-version-cli")
      File.write(binary, <<~SH)
        #!/usr/bin/env bash
        trap '' TERM
        deadline=$((SECONDS + 2))
        while [ "$SECONDS" -lt "$deadline" ]; do :; done
      SH
      File.chmod(0o755, binary)
      profile = make_profile(
        bin_default: binary, env_bin_override_key: nil, min_version: "1.0.0"
      )
      started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      with_version_check_timeout(0.1) do
        err = assert_raises(Hive::AgentError) { profile.check_version! }
        assert_match(/version check timed out/, err.message)
      end
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at
      assert_operator elapsed, :<, 1.0
    end
  end

  def test_check_version_caches_result
    profile = make_profile(min_version: "1.0.0")
    ENV["HIVE_FAKE_CLAUDE_VERSION"] = "2.0.0"
    first = profile.check_version!
    # Swap to a version below the floor; cached value should be returned
    # without re-running the binary, so no error is raised.
    ENV["HIVE_FAKE_CLAUDE_VERSION"] = "0.0.1"
    second = profile.check_version!
    assert_equal first, second
  end

  def test_invalid_status_detection_mode_raises_at_construction
    err = assert_raises(ArgumentError) do
      Hive::AgentProfile.new(
        name: :bad,
        bin_default: "x",
        headless_flag: "-p",
        version_flag: "--version",
        skill_syntax_format: "/%{skill}",
        status_detection_mode: :unknown_mode
      )
    end
    assert_match(/unknown status_detection_mode/, err.message)
  end

  def test_invalid_prompt_style_raises_at_construction
    err = assert_raises(ArgumentError) do
      make_profile(prompt_style: :unknown_style)
    end

    assert_match(/unknown prompt_style/, err.message)
  end

  def test_preflight_default_is_noop
    profile = make_profile
    assert_nil profile.preflight!
  end

  def test_usage_extractor_default_is_noop
    profile = make_profile
    assert_nil profile.extract_usage_event("not-json")
  end

  def test_workspace_write_mode_fails_closed_without_profile_capability
    profile = make_profile(permission_skip_flag: "--dangerous")

    error = assert_raises(ArgumentError) do
      profile.permission_flags(Hive::AgentProfile::WORKSPACE_WRITE_PERMISSION_MODE)
    end

    assert_includes error.message, "cannot enforce workspace-write"
  end

  def test_workspace_write_mode_uses_frozen_profile_flags_without_bypass
    profile = make_profile(
      permission_skip_flag: "--dangerous",
      workspace_write_flags: [ "--sandbox", "workspace-write" ]
    )

    flags = profile.permission_flags(Hive::AgentProfile::WORKSPACE_WRITE_PERMISSION_MODE)

    assert_equal [ "--sandbox", "workspace-write" ], flags
    refute_includes flags, "--dangerous"
    assert profile.workspace_write_supported?
  end

  def test_cli_capability_must_be_declared
    error = assert_raises(Hive::AgentError) do
      make_profile.require_cli_capability!(:safe_mode)
    end

    assert_includes error.message, "does not declare CLI capability"
  end

  def test_cli_capabilities_require_a_hash_and_non_empty_flags
    type_error = assert_raises(ArgumentError) { make_profile(cli_capabilities: [ "--safe-mode" ]) }
    empty_error = assert_raises(ArgumentError) { make_profile(cli_capabilities: { safe_mode: [] }) }

    assert_includes type_error.message, "must be a Hash"
    assert_includes empty_error.message, "must declare at least one flag"
  end

  def test_cli_capability_help_failure_is_explicit
    with_tmp_dir do |dir|
      binary = capability_binary(dir, help: "", help_exit: 2)
      profile = make_profile(
        bin_default: binary, env_bin_override_key: nil,
        cli_capabilities: { safe_mode: [ "--safe-mode" ] }
      )

      error = assert_raises(Hive::AgentError) { profile.require_cli_capability!(:safe_mode) }

      assert_includes error.message, "capability check failed"
    end
  end

  def test_cli_capability_verifies_options_without_treating_values_as_flags
    with_tmp_dir do |dir|
      binary = File.join(dir, "valued-capability-cli")
      File.write(binary, <<~SH)
        #!/bin/sh
        if [ "${1:-}" = "--version" ]; then
          echo "2.1.179 (Claude Code)"
          exit 0
        fi
        printf '%s\n' '--safe-mode --tools <tools...>'
      SH
      File.chmod(0o755, binary)
      profile = make_profile(
        bin_default: binary, env_bin_override_key: nil,
        cli_capabilities: {
          patrol: [ "--safe-mode", "--tools", "Read,Grep,Glob" ]
        }
      )

      assert_equal [ "--safe-mode", "--tools", "Read,Grep,Glob" ],
                   profile.require_cli_capability!(:patrol)
    end
  end

  def test_cli_capability_help_timeout_terminates_and_reaps_hung_process
    with_tmp_dir do |dir|
      pid_path = File.join(dir, "capability-help.pid")
      binary = File.join(dir, "hung-capability-cli")
      File.write(binary, <<~SH)
        #!/usr/bin/env bash
        if [ "${1:-}" = "--version" ]; then
          echo "2.1.179 (Claude Code)"
          exit 0
        fi
        if [ "${1:-}" = "--safe-mode" ] && [ "${2:-}" = "--help" ]; then
          printf '%s\n' "$$" > #{pid_path.inspect}
          trap '' TERM
          deadline=$((SECONDS + 2))
          while [ "$SECONDS" -lt "$deadline" ]; do :; done
        fi
      SH
      File.chmod(0o755, binary)
      profile = make_profile(
        bin_default: binary, env_bin_override_key: nil,
        cli_capabilities: { safe_mode: [ "--safe-mode" ] }
      )

      started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      error = with_version_check_timeout(0.1) do
        assert_raises(Hive::AgentError) { profile.require_cli_capability!(:safe_mode) }
      end
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at

      assert_includes error.message, "capability check timed out"
      assert_operator elapsed, :<, 1.0
      pid = Integer(File.read(pid_path), 10)
      assert_raises(Errno::ESRCH) { Process.kill(0, pid) }
    end
  end

  def test_bounded_capture_tolerates_pipe_close_races
    profile = make_profile
    stdin_closed = false
    stdin = Object.new
    stdin.define_singleton_method(:close) { stdin_closed = true }
    stdin.define_singleton_method(:closed?) { stdin_closed }
    pipe = lambda do
      Object.new.tap do |io|
        io.define_singleton_method(:read) { "" }
        io.define_singleton_method(:closed?) { false }
        io.define_singleton_method(:close) { raise IOError, "already closed" }
      end
    end
    waiter = Object.new
    waiter.define_singleton_method(:alive?) { false }
    waiter.define_singleton_method(:value) { :status }
    replacement = lambda do |*_argv, **_options|
      [ stdin, pipe.call, pipe.call, waiter ]
    end

    result = with_replaced_singleton_method(Open3, :popen3, replacement) do
      profile.send(:bounded_capture3, "fake", timeout_sec: 0.1)
    end

    assert_equal [ "", "", :status ], result
  end

  def test_capture_cleanup_tolerates_concurrent_pipe_closure
    profile = make_profile
    unreadable = Object.new
    unreadable.define_singleton_method(:read) { raise IOError, "closed" }
    assert_equal "", profile.send(:capture_reader, unreadable).value

    closing = Object.new
    closing.define_singleton_method(:closed?) { false }
    closing.define_singleton_method(:close) { raise IOError, "closed" }
    assert_empty profile.send(:stop_capture_readers, [], closing)
  end

  def test_process_group_probes_handle_exit_and_permission_races
    profile = make_profile
    missing = lambda { |_signal, _pid| raise Errno::ESRCH }
    with_replaced_singleton_method(Process, :kill, missing) do
      assert_nil profile.send(:signal_capture_process_group, "TERM", 123)
      refute profile.send(:capture_process_group_alive?, 123)
    end

    denied = lambda { |_signal, _pid| raise Errno::EPERM }
    with_replaced_singleton_method(Process, :kill, denied) do
      assert profile.send(:capture_process_group_alive?, 123)
    end
  end

  def test_cli_capability_binary_disappearing_after_version_check_is_explicit
    with_tmp_dir do |dir|
      binary = capability_binary(dir, help: "--safe-mode")
      profile = make_profile(
        bin_default: binary, env_bin_override_key: nil,
        cli_capabilities: { safe_mode: [ "--safe-mode" ] }
      )
      profile.check_version!
      FileUtils.rm_f(binary)

      error = assert_raises(Hive::AgentError) { profile.require_cli_capability!(:safe_mode) }

      assert_includes error.message, "capability check could not run"
    end
  end

  def test_with_overrides_preserves_cli_capabilities
    profile = make_profile(cli_capabilities: { safe_mode: [ "--safe-mode" ] })

    overridden = profile.with_overrides("min_version" => "9.9.9")

    assert_equal({ safe_mode: [ "--safe-mode" ] }, overridden.cli_capabilities)
  end

  def test_with_overrides_preserves_initial_context_reserve
    profile = make_profile(initial_context_tokens: 12_345)

    overridden = profile.with_overrides("min_version" => "9.9.9")

    assert_equal 12_345, overridden.initial_context_tokens
  end

  # --- with_overrides ---------------------------------------------------

  def test_with_overrides_returns_self_for_nil_or_empty
    profile = make_profile
    assert_same profile, profile.with_overrides(nil)
    assert_same profile, profile.with_overrides({})
  end

  def test_with_overrides_replaces_bin_default
    profile = make_profile(bin_default: "claude")
    overridden = profile.with_overrides("bin" => "/opt/custom/claude")
    refute_same profile, overridden
    assert_equal "/opt/custom/claude", overridden.bin_default
    # Original profile is not mutated.
    assert_equal "claude", profile.bin_default
  end

  def test_with_overrides_replaces_min_version
    profile = make_profile(min_version: "1.0.0")
    overridden = profile.with_overrides("min_version" => "9.9.9")
    assert_equal "9.9.9", overridden.min_version
  end

  def test_with_overrides_replaces_env_override_key
    profile = make_profile(env_bin_override_key: "HIVE_CLAUDE_BIN")
    overridden = profile.with_overrides("env_override" => "MY_CUSTOM_BIN")
    assert_equal "MY_CUSTOM_BIN", overridden.env_bin_override_key
  end

  def test_with_overrides_preserves_prompt_style
    profile = make_profile(prompt_style: :headless_flag_value)

    overridden = profile.with_overrides("min_version" => "9.9.9")

    assert_equal :headless_flag_value, overridden.prompt_style
  end

  def test_with_overrides_raises_for_non_hash
    profile = make_profile

    err = assert_raises(Hive::ConfigError) do
      profile.with_overrides("not-a-hash")
    end

    assert_match(/override must be a Hash/, err.message)
  end

  def test_with_overrides_raises_for_unknown_key
    profile = make_profile
    err = assert_raises(Hive::ConfigError) do
      profile.with_overrides("not_a_real_key" => "x")
    end
    assert_match(/not_a_real_key/, err.message)
  end

  def test_with_overrides_returns_frozen_profile
    profile = make_profile
    overridden = profile.with_overrides("bin" => "/x")
    assert overridden.frozen?
  end
  def test_usage_extractor_errors_are_ignored
    profile = make_profile(usage_extractor: ->(_event) { raise "bad usage payload" })

    assert_nil profile.extract_usage_event({ "type" => "result" })
  end


  def capability_binary(dir, help:, help_exit: 0)
    path = File.join(dir, "capable-cli")
    File.write(path, <<~SH)
      #!/bin/sh
      if [ "${1:-}" = "--version" ]; then
        echo "2.1.179 (Claude Code)"
        exit 0
      fi
      if [ "${1:-}" = "--safe-mode" ] && [ "${2:-}" = "--help" ]; then
        printf '%s\\n' #{help.inspect}
        exit #{help_exit}
      fi
      exit 0
    SH
    File.chmod(0o755, path)
    path
  end

  def with_version_check_timeout(seconds)
    original = Hive::AgentProfile::VERSION_CHECK_TIMEOUT_SEC
    Hive::AgentProfile.send(:remove_const, :VERSION_CHECK_TIMEOUT_SEC)
    Hive::AgentProfile.const_set(:VERSION_CHECK_TIMEOUT_SEC, seconds)
    yield
  ensure
    Hive::AgentProfile.send(:remove_const, :VERSION_CHECK_TIMEOUT_SEC)
    Hive::AgentProfile.const_set(:VERSION_CHECK_TIMEOUT_SEC, original)
  end
end
