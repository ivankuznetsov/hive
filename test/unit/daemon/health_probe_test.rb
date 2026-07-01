require "test_helper"
require "hive/daemon/health_probe"

class HiveDaemonHealthProbeTest < Minitest::Test
  include HiveTestHelper

  Status = Struct.new(:success_value, :exitstatus, keyword_init: true) do
    def success?
      success_value
    end
  end

  FakeDoctor = Struct.new(:rows, :exit_code, keyword_init: true) do
    def call
      exit_code || 0
    end
  end

  FakeProfile = Struct.new(:bin, :version, :version_error, keyword_init: true) do
    def check_version!
      raise version_error if version_error

      version || "2.1.118"
    end
  end

  def health_probe(doctor_rows: [], capture3: nil, timeout_runner: nil)
    doctor = FakeDoctor.new(rows: doctor_rows)
    Hive::Daemon::HealthProbe.new(
      config: Hive::Config::DEFAULTS,
      project_root: Dir.pwd,
      env: { "CODEX_HOME" => "/tmp/codex-home" },
      tick_id: "tick-1",
      doctor_factory: -> { doctor },
      capture3: capture3 || ->(_env, *_cmd) { [ "", "", Status.new(success_value: true, exitstatus: 0) ] },
      timeout_runner: timeout_runner || ->(_seconds, &block) { block.call }
    )
  end

  def test_codex_probe_passes_when_login_and_smoke_pass
    calls = []
    probe = health_probe(
      capture3: lambda do |env, *cmd|
        calls << { env: env, cmd: cmd }
        [ "ok", "", Status.new(success_value: true, exitstatus: 0) ]
      end
    )

    result = probe.probe(:codex_auth)

    assert_equal true, result[:ok]
    assert_equal %w[doctor codex_login_status codex_exec_smoke], result[:probes].map { |p| p[:name] }
    assert_equal [ "codex", "login", "status" ], calls[0][:cmd]
    assert_equal [ "codex", "exec", "--json", "Reply with OK." ], calls[1][:cmd]
    assert_equal "/tmp/codex-home", calls[0][:env]["CODEX_HOME"]
  end

  def test_codex_probe_stops_after_logged_out_status
    calls = []
    probe = health_probe(
      capture3: lambda do |_env, *cmd|
        calls << cmd
        [ "", "not logged in", Status.new(success_value: false, exitstatus: 1) ]
      end
    )

    result = probe.probe(:codex_auth)

    assert_equal false, result[:ok]
    assert_equal %w[doctor codex_login_status], result[:probes].map { |p| p[:name] }
    assert_equal 1, calls.size
    assert_equal "not logged in", result[:probes].last[:stderr_tail]
  end

  def test_codex_smoke_timeout_is_not_healthy
    calls = 0
    # Call order is doctor (1), codex_login_status (2), codex_exec_smoke (3):
    # the doctor probe now shares this injected timeout runner, so the smoke
    # probe is the third invocation.
    timeout_runner = lambda do |_seconds, &block|
      calls += 1
      raise Timeout::Error if calls == 3

      block.call
    end
    probe = health_probe(timeout_runner: timeout_runner)

    result = probe.probe(:codex_auth)

    assert_equal false, result[:ok]
    smoke = result[:probes].find { |p| p[:name] == "codex_exec_smoke" }
    assert_includes smoke[:stderr_tail], "timed out"
  end

  def test_doctor_failure_blocks_reason_specific_probe
    probe = health_probe(doctor_rows: [ { label: "claude", status: "missing" } ])

    result = probe.probe(:codex_auth)

    assert_equal false, result[:ok]
    assert_equal [ "doctor" ], result[:probes].map { |p| p[:name] }
    assert_includes result[:probes].first[:stdout_tail], "claude=missing"
  end

  def test_same_tick_reason_is_cached
    calls = 0
    probe = health_probe(
      capture3: lambda do |_env, *_cmd|
        calls += 1
        [ "", "", Status.new(success_value: true, exitstatus: 0) ]
      end
    )

    probe.probe(:codex_auth)
    probe.probe(:codex_auth)

    assert_equal 2, calls, "login + smoke should run once each within a tick"
  end

  def test_start_tick_clears_cache
    calls = 0
    probe = health_probe(
      capture3: lambda do |_env, *_cmd|
        calls += 1
        [ "", "", Status.new(success_value: true, exitstatus: 0) ]
      end
    )

    probe.probe(:codex_auth)
    probe.start_tick("tick-2")
    probe.probe(:codex_auth)

    assert_equal 4, calls
  end

  def test_claude_probe_checks_wrapper_tmux_and_version
    profile = FakeProfile.new(bin: "claude", version: "2.1.120")
    with_replaced_singleton_method(Hive::ClaudeLauncher, :tmux_status, -> { [ :present, "tmux ok" ] }) do
      with_replaced_singleton_method(Hive::AgentProfiles, :lookup, ->(_name, cfg: nil) { profile }) do
        result = health_probe.probe(:claude_launcher)

        assert_equal true, result[:ok]
        assert_equal %w[doctor claude_wrapper claude_tmux claude_version], result[:probes].map { |p| p[:name] }
      end
    end
  end

  def test_claude_wrapper_missing_is_not_healthy
    with_replaced_singleton_method(File, :file?, lambda { |path|
      return false if path.to_s.end_with?("interactive_claude_wrapper.sh")

      File.exist?(path)
    }) do
      result = health_probe.probe(:claude_launcher)

      assert_equal false, result[:ok]
      wrapper = result[:probes].find { |p| p[:name] == "claude_wrapper" }
      assert_equal false, wrapper[:ok]
    end
  end

  def test_claude_version_below_min_is_not_healthy
    profile = FakeProfile.new(bin: "claude", version_error: Hive::AgentError.new("claude 2.0.0 below minimum"))
    with_replaced_singleton_method(Hive::ClaudeLauncher, :tmux_status, -> { [ :present, "tmux ok" ] }) do
      with_replaced_singleton_method(Hive::AgentProfiles, :lookup, ->(_name, cfg: nil) { profile }) do
        result = health_probe.probe(:claude_launcher)

        assert_equal false, result[:ok]
        version = result[:probes].find { |p| p[:name] == "claude_version" }
        assert_includes version[:stderr_tail], "below minimum"
      end
    end
  end

  def test_doctor_config_error_with_nil_rows_fails_closed
    doctor = FakeDoctor.new(rows: nil, exit_code: Hive::Commands::Doctor::EXIT_CONFIG_ERROR)
    probe = Hive::Daemon::HealthProbe.new(
      config: Hive::Config::DEFAULTS,
      project_root: Dir.pwd,
      env: { "CODEX_HOME" => "/tmp/codex-home" },
      tick_id: "tick-1",
      doctor_factory: -> { doctor },
      capture3: ->(_env, *_cmd) { [ "", "", Status.new(success_value: true, exitstatus: 0) ] },
      timeout_runner: ->(_seconds, &block) { block.call }
    )

    result = probe.probe(:codex_auth)

    assert_equal false, result[:ok], "a doctor that errored with no rows must block, not pass the gate"
    assert_equal [ "doctor" ], result[:probes].map { |p| p[:name] }
    doctor_probe = result[:probes].first
    assert_equal false, doctor_probe[:ok]
    assert_includes doctor_probe[:stdout_tail], "no rows"
  end

  def test_doctor_nonzero_exit_with_clean_rows_fails_closed
    doctor = FakeDoctor.new(rows: [ { label: "claude", status: "present" } ], exit_code: 65)
    probe = Hive::Daemon::HealthProbe.new(
      config: Hive::Config::DEFAULTS,
      project_root: Dir.pwd,
      doctor_factory: -> { doctor },
      capture3: ->(_env, *_cmd) { [ "", "", Status.new(success_value: true, exitstatus: 0) ] },
      timeout_runner: ->(_seconds, &block) { block.call }
    )

    result = probe.probe(:codex_auth)

    assert_equal false, result[:ok]
    assert_equal [ "doctor" ], result[:probes].map { |p| p[:name] }
  end

  def test_doctor_timeout_fails_closed
    doctor = FakeDoctor.new(rows: [ { label: "claude", status: "present" } ])
    probe = Hive::Daemon::HealthProbe.new(
      config: Hive::Config::DEFAULTS,
      project_root: Dir.pwd,
      doctor_factory: -> { doctor },
      capture3: ->(_env, *_cmd) { [ "", "", Status.new(success_value: true, exitstatus: 0) ] },
      # First invocation is the doctor probe; time it out to prove the outer
      # timeout wraps the in-process doctor and fails CLOSED.
      timeout_runner: ->(_seconds, &_block) { raise Timeout::Error }
    )

    result = probe.probe(:codex_auth)

    assert_equal false, result[:ok]
    assert_equal [ "doctor" ], result[:probes].map { |p| p[:name] }
    assert_includes result[:probes].first[:stderr_tail], "timed out"
  end

  def test_unknown_category_is_not_healthy
    result = health_probe.probe(:mystery_category)

    assert_equal false, result[:ok]
    assert_equal %w[doctor unknown_reason], result[:probes].map { |p| p[:name] }
    assert_includes result[:probes].last[:stderr_tail], "unknown health probe category"
  end

  def test_run_probe_top_level_rescue_emits_health_probe_error
    probe = health_probe
    probe.define_singleton_method(:doctor_probe) { raise "kaboom" }

    result = probe.probe(:codex_auth)

    assert_equal false, result[:ok]
    assert_equal [ "health_probe_error" ], result[:probes].map { |p| p[:name] }
    assert_includes result[:probes].first[:stderr_tail], "kaboom"
  end

  def test_doctor_generic_error_fails_closed
    doctor = Object.new
    doctor.define_singleton_method(:call) { raise RuntimeError, "doctor blew up" }
    doctor.define_singleton_method(:rows) { [] }
    probe = Hive::Daemon::HealthProbe.new(
      config: Hive::Config::DEFAULTS,
      project_root: Dir.pwd,
      doctor_factory: -> { doctor },
      capture3: ->(_env, *_cmd) { [ "", "", Status.new(success_value: true, exitstatus: 0) ] },
      timeout_runner: ->(_seconds, &block) { block.call }
    )

    result = probe.probe(:codex_auth)

    assert_equal false, result[:ok], "a non-timeout doctor error must fail closed"
    doctor_probe = result[:probes].find { |p| p[:name] == "doctor" }
    assert_equal false, doctor_probe[:ok]
    assert_includes doctor_probe[:stderr_tail], "RuntimeError: doctor blew up"
  end

  def test_default_doctor_constructor_is_used_without_injection
    fake = FakeDoctor.new(rows: [ { label: "claude", status: "present" } ], exit_code: 0)
    # No doctor_factory injected: the probe must build its doctor via the real
    # default_doctor -> Hive::Commands::Doctor.new(...) path. Stub .new to keep
    # the doctor hermetic while still exercising the constructor call site.
    probe = with_replaced_singleton_method(Hive::Commands::Doctor, :new, ->(**_kwargs) { fake }) do
      built = Hive::Daemon::HealthProbe.new(
        config: Hive::Config::DEFAULTS,
        project_root: Dir.pwd,
        capture3: ->(_env, *_cmd) { [ "", "", Status.new(success_value: true, exitstatus: 0) ] },
        timeout_runner: ->(_seconds, &block) { block.call }
      )
      built.probe(:codex_auth)
      built
    end

    result = probe.probe(:codex_auth)
    doctor_probe = result[:probes].find { |p| p[:name] == "doctor" }
    assert_equal "doctor", doctor_probe[:name]
    assert_equal true, doctor_probe[:ok], "the default_doctor path must run a real Doctor.new"
  end

  def test_claude_wrapper_syscall_error_fails_closed
    with_replaced_singleton_method(Hive::ClaudeLauncher, :tmux_status, -> { [ :present, "tmux ok" ] }) do
      with_replaced_singleton_method(File, :file?, lambda { |path|
        raise Errno::EACCES, path.to_s if path.to_s.end_with?("interactive_claude_wrapper.sh")

        File.exist?(path)
      }) do
        result = health_probe.probe(:claude_launcher)

        assert_equal false, result[:ok]
        wrapper = result[:probes].find { |p| p[:name] == "claude_wrapper" }
        assert_equal false, wrapper[:ok], "a SystemCallError on File.file? must fail the wrapper probe closed"
        assert_includes wrapper[:stderr_tail], "Errno::EACCES"
      end
    end
  end

  def test_claude_tmux_status_error_fails_closed
    profile = FakeProfile.new(bin: "claude", version: "2.1.120")
    with_replaced_singleton_method(Hive::ClaudeLauncher, :tmux_status, -> { raise "tmux server unreachable" }) do
      with_replaced_singleton_method(Hive::AgentProfiles, :lookup, ->(_name, cfg: nil) { profile }) do
        result = health_probe.probe(:claude_launcher)

        assert_equal false, result[:ok]
        tmux = result[:probes].find { |p| p[:name] == "claude_tmux" }
        assert_equal false, tmux[:ok], "a raised tmux_status must fail the tmux probe closed"
        assert_includes tmux[:stderr_tail], "tmux server unreachable"
      end
    end
  end

  def test_shell_probe_generic_error_fails_closed
    capture3 = ->(_env, *_cmd) { raise "spawn failed: ENOENT" }
    probe = health_probe(capture3: capture3)

    result = probe.probe(:codex_auth)

    assert_equal false, result[:ok]
    login = result[:probes].find { |p| p[:name] == "codex_login_status" }
    assert_equal false, login[:ok], "a non-timeout shell error must fail the probe closed"
    assert_includes login[:stderr_tail], "spawn failed: ENOENT"
  end

  def test_codex_bin_lookup_failure_falls_back_to_codex_literal
    calls = []
    capture3 = lambda do |_env, *cmd|
      calls << cmd
      [ "ok", "", Status.new(success_value: true, exitstatus: 0) ]
    end
    probe = health_probe(capture3: capture3)

    with_replaced_singleton_method(Hive::AgentProfiles, :lookup, ->(_name, cfg: nil) { raise "no codex profile" }) do
      result = probe.probe(:codex_auth)

      assert_equal true, result[:ok]
    end

    # codex_bin rescues the failed lookup and falls back to the "codex" literal,
    # so the shell probe argv must still begin with "codex".
    assert_equal "codex", calls[0][0], "codex_bin must fall back to the 'codex' literal on lookup failure"
    assert_equal [ "codex", "login", "status" ], calls[0]
  end

  def test_elapsed_ms_swallows_clock_error_and_omits_ms
    probe = health_probe
    calls = 0
    # First monotonic_ms call seeds `started`; the second (inside elapsed_ms)
    # raises, so elapsed_ms rescues to nil and probe_result.compact drops :ms.
    probe.define_singleton_method(:monotonic_ms) do
      calls += 1
      raise "clock unavailable" if calls >= 2

      0
    end

    result = probe.probe(:codex_auth)

    doctor_probe = result[:probes].find { |p| p[:name] == "doctor" }
    refute doctor_probe.key?(:ms), "a raised clock read in elapsed_ms must drop the :ms key (nil compacted away)"
  end
end
